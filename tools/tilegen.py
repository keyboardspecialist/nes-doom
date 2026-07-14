#!/usr/bin/env python3
"""CHR-ROM generator for the NES Doom PoC.

--test mode (M1/M2): hand-built diagnostic banks (see test_chr below).

--game mode (M4/M5): 2 synthetic textures (brick, stone) -> banks 0-7,
  flats/status at bank 8.

--wad WAD --texlist texlist.json (E1M1): compose each named texture from the
  WAD, quantize to 3 luminance bins (colors 1-3), same slice pipeline ->
  4 banks per texture, flats at bank 4*ntex.

Slices: per (texture, height class, u-phase), an 8-px-wide column of the
64x64 source rescaled to H tiles, contiguous within one 4KB bank. LUT output
(luts.s): slice_tile[], slice_bank[] (ntex*104 entries) + tex_base_lo/hi[]
(16-bit offsets = tex*104) for pointer-based lookup in src/render.s.
"""
import argparse
import json

# Canonical 2C02 NES palette (RGB), indexed $00-$3F: row = luminance (0=dark),
# column = hue (0 = gray).
NES_PAL = [
    (84, 84, 84), (0, 30, 116), (8, 16, 144), (48, 0, 136),
    (68, 0, 100), (92, 0, 48), (84, 4, 0), (60, 24, 0),
    (32, 42, 0), (8, 58, 0), (0, 64, 0), (0, 60, 0),
    (0, 50, 60), (0, 0, 0), (0, 0, 0), (0, 0, 0),
    (152, 150, 152), (8, 76, 196), (48, 50, 236), (92, 30, 228),
    (136, 20, 176), (160, 20, 100), (152, 34, 32), (120, 60, 0),
    (84, 90, 0), (40, 114, 0), (8, 124, 0), (0, 118, 40),
    (0, 102, 120), (0, 0, 0), (0, 0, 0), (0, 0, 0),
    (236, 238, 236), (76, 154, 236), (120, 124, 236), (176, 98, 236),
    (228, 84, 236), (236, 88, 180), (236, 106, 100), (212, 136, 32),
    (160, 170, 0), (116, 196, 0), (76, 208, 32), (56, 204, 108),
    (56, 180, 204), (60, 60, 60), (0, 0, 0), (0, 0, 0),
    (236, 238, 236), (168, 204, 236), (188, 188, 236), (212, 178, 236),
    (236, 174, 236), (236, 174, 212), (236, 180, 176), (228, 196, 144),
    (204, 210, 120), (180, 222, 120), (168, 226, 144), (152, 226, 180),
    (160, 214, 228), (160, 162, 160), (0, 0, 0), (0, 0, 0),
]

TILE_BYTES = 16
BANK_TILES = 256          # 4KB bank
BANK_BYTES = BANK_TILES * TILE_BYTES
CLASSES = [1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20]
BANKS_PER_TEX = 4
SLICES_PER_TEX = len(CLASSES) * 8


def solid(color):
    p0 = 0xFF if color & 1 else 0x00
    p1 = 0xFF if color & 2 else 0x00
    return bytes([p0] * 8 + [p1] * 8)


def checker(c1, c2, cell=4):
    rows0, rows1 = [], []
    for y in range(8):
        b0 = b1 = 0
        for x in range(8):
            c = c1 if ((x // cell + y // cell) % 2 == 0) else c2
            if c & 1:
                b0 |= 0x80 >> x
            if c & 2:
                b1 |= 0x80 >> x
        rows0.append(b0)
        rows1.append(b1)
    return bytes(rows0 + rows1)


def encode_tile(pix):
    """pix = 8x8 list of color indices 0-3 -> 16 bytes planar."""
    p0, p1 = [], []
    for y in range(8):
        b0 = b1 = 0
        for x in range(8):
            c = pix[y][x]
            if c & 1:
                b0 |= 0x80 >> x
            if c & 2:
                b1 |= 0x80 >> x
        p0.append(b0)
        p1.append(b1)
    return bytes(p0 + p1)


def brick_texture():
    """64x64, colors 1-3 only (0 would show the backdrop through walls)."""
    tex = [[2] * 64 for _ in range(64)]  # tex[y][x]
    for y in range(64):
        course = y // 16
        for x in range(64):
            if y % 16 == 0:
                tex[y][x] = 1
            elif (x + (16 if course % 2 else 0)) % 32 == 0:
                tex[y][x] = 1
            elif y % 16 == 1 or (x + (16 if course % 2 else 0)) % 32 == 1:
                tex[y][x] = 3
    return tex


def stone_texture():
    tex = [[3] * 64 for _ in range(64)]
    for y in range(64):
        for x in range(64):
            bx, by = x % 32, y % 32
            if by < 2 or bx < 2:
                tex[y][x] = 1
            elif (x * 7 + y * 13) % 23 == 0:
                tex[y][x] = 2
    return tex


def wad_textures(wadpath, texlist):
    """Compose + quantize each named texture to a 64x64 map of colors 1-3.
    Returns (textures, per_tex_bins): chroma-weighted bin RGB per texture,
    so colorful pixels drive the hue, not gray mortar/shadows."""
    import wadlib
    wad = wadlib.Wad(wadpath)
    defs = wadlib.texture_defs(wad)
    pnames = wadlib._patch_names(wad)
    pal = wadlib.playpal(wad)
    lum = [0.299 * r + 0.587 * g + 0.114 * b for (r, g, b) in pal]
    out = []
    tex_bins = []
    for name in texlist:
        w, h, img = wadlib.compose_texture(wad, defs, pnames, name)
        # sample to 64x64 (tile smaller textures, compress taller/wider)
        smp = [[img[(x * w) // 64][(y * h) // 64] for x in range(64)]
               for y in range(64)]
        lums = sorted(lum[p] for row in smp for p in row)
        p33, p66 = lums[len(lums) // 3], lums[(2 * len(lums)) // 3]
        # brightest -> color 1 (top of the palette ramp), darkest -> 3
        sums = {1: [0, 0, 0, 0], 2: [0, 0, 0, 0], 3: [0, 0, 0, 0]}
        tex = []
        for row in smp:
            trow = []
            for p in row:
                c = 1 if lum[p] >= p66 else (2 if lum[p] >= p33 else 3)
                trow.append(c)
                s = sums[c]
                r, g, b = pal[p]
                wt = max(r, g, b) - min(r, g, b) + 1
                s[0] += r * wt
                s[1] += g * wt
                s[2] += b * wt
                s[3] += wt
            tex.append(trow)
        out.append(tex)
        tex_bins.append({c: (s[0] / max(s[3], 1), s[1] / max(s[3], 1),
                             s[2] / max(s[3], 1)) for c, s in sums.items()})
    return out, tex_bins


def split_ramps(tex_bins):
    """Assign each texture to ramp 0 (warm) or 1 (cool) by median warmth,
    then merge bins per ramp. Returns (ramp_of[], binsA, binsB)."""
    warmth = [b[2][0] - b[2][2] for b in tex_bins]   # mid bin r - b
    order = sorted(range(len(warmth)), key=lambda i: -warmth[i])
    ramp_of = [1] * len(tex_bins)
    for i in order[:max(1, len(order) // 2)]:
        ramp_of[i] = 0
    merged = [{c: [0.0, 0.0, 0.0, 0] for c in (1, 2, 3)} for _ in range(2)]
    for i, bins in enumerate(tex_bins):
        m = merged[ramp_of[i]]
        for c in (1, 2, 3):
            for k in range(3):
                m[c][k] += bins[c][k]
            m[c][3] += 1
    out = []
    for m in merged:
        out.append({c: (v[0] / max(v[3], 1), v[1] / max(v[3], 1),
                        v[2] / max(v[3], 1)) for c, v in m.items()})
    return ramp_of, out[0], out[1]


BACKDROP = 0x00     # ceiling color: ceilings are BLANK tiles showing the
                    # backdrop, which lets shared edge tiles carry a
                    # "ceiling-colored" region under any wall palette


def ramp_base(bins):
    """bins {1: rgb, 2: rgb, 3: rgb} -> 3 NES colors at fixed rows 3/2/1.

    Doom textures are dark overall, so raw nearest-color matching lands in
    NES row 0 and the light ramp dies. Instead: pin the bins to fixed rows
    and match only the HUE, comparing against the bin color scaled to each
    candidate's luminance."""
    rows = {1: 3, 2: 2, 3: 1}
    base = []
    for c in (1, 2, 3):
        rgb = bins[c]
        row = rows[c]
        lum = 0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2]
        best, bd = row << 4, 1e18
        for col in range(13):           # cols 13-15 are blacker-than-black
            nes = NES_PAL[(row << 4) | col]
            nlum = 0.299 * nes[0] + 0.587 * nes[1] + 0.114 * nes[2]
            s = nlum / max(lum, 1.0)
            d = (0.3 * (rgb[0] * s - nes[0]) ** 2
                 + 0.59 * (rgb[1] * s - nes[1]) ** 2
                 + 0.11 * (rgb[2] * s - nes[2]) ** 2)
            if d < bd:
                best, bd = (row << 4) | col, d
        if best & 0x0F == 0:
            best -= 0x10    # NES $30 and $20 are both white: gray ramps use
        base.append(best)   # rows 2/1/0 so all three stay distinct
    return base


def derive_palettes(bins_a, bins_b):
    """Two hue ramps x two light levels:
    palette 0/1 = ramp A light 0/1, palette 2/3 = ramp B light 0/1."""
    pals = []
    for base in (ramp_base(bins_a), ramp_base(bins_b)):
        for light in range(2):
            pals.append(BACKDROP)
            for v in base:
                row, hue = v >> 4, v & 0x0F
                r = row - light
                pals.append(0x0F if r < 0 else (r << 4) | hue)
    return pals


def slice_banks(textures):
    """Prescale every (texture, class, phase) column into contiguous tiles."""
    flat_bank = len(textures) * BANKS_PER_TEX
    banks = [bytearray() for _ in range(flat_bank + 1)]
    slice_tile, slice_bank = [], []
    for ti, tex in enumerate(textures):
        bank = ti * BANKS_PER_TEX
        limit = bank + BANKS_PER_TEX
        for h in CLASSES:
            for p in range(8):
                if len(banks[bank]) // TILE_BYTES + h > BANK_TILES:
                    bank += 1
                    assert bank < limit, "texture slices overflowed 4 banks"
                slice_tile.append(len(banks[bank]) // TILE_BYTES)
                slice_bank.append(bank)
                hpx = h * 8
                col = [[tex[y * 64 // hpx][p * 8 + x] for x in range(8)]
                       for y in range(hpx)]
                for t in range(h):
                    banks[bank].extend(encode_tile(col[t * 8:(t + 1) * 8]))
    fb = banks[flat_bank]
    fb.extend(solid(1))          # tile 0
    fb.extend(solid(2))          # tile 1
    fb.extend(solid(3))          # tile 2: floor
    fb.extend(checker(1, 2))     # tile 3: status bar
    fb.extend(bytes(16))         # tile 4: blank -> backdrop (= ceiling)
    for j in range(1, 8):        # tiles 5-11: top edges, j wall rows below
        fb.extend(encode_tile([[0] * 8] * (8 - j) + [[2] * 8] * j))
    for j in range(1, 8):        # tiles 12-18: bottom edges, j wall rows above
        fb.extend(encode_tile([[2] * 8] * j + [[3] * 8] * (8 - j)))
    data = bytearray()
    for b in banks:
        data.extend(b.ljust(BANK_BYTES, b"\0"))
    used = sum(len(b) // TILE_BYTES for b in banks)
    return bytes(data), slice_tile, slice_bank, used, flat_bank


def write_luts(path, slice_tile, slice_bank, ntex, bg_palettes, ramp_of):
    bases = [min(t, 15) * SLICES_PER_TEX for t in range(16)]
    ramps = [(ramp_of[t] << 7) if t < len(ramp_of) else 0 for t in range(16)]
    with open(path, "w") as f:
        f.write("; GENERATED by tools/tilegen.py — do not edit\n")
        f.write(".export slice_tile, slice_bank, tex_base_lo, tex_base_hi\n")
        f.write(".export bg_palettes, tex_ramp\n")
        f.write('.segment "LUT00"\n')
        for name, vals in (("slice_tile", slice_tile), ("slice_bank", slice_bank),
                           ("tex_base_lo", [b & 0xFF for b in bases]),
                           ("tex_base_hi", [b >> 8 for b in bases]),
                           ("bg_palettes", bg_palettes),
                           ("tex_ramp", ramps)):
            f.write(f"{name}:\n")
            for i in range(0, len(vals), 16):
                f.write("    .byte " + ", ".join(f"${v:02X}" for v in vals[i:i+16]) + "\n")


def test_chr():
    banks = 72
    data = bytearray(banks * BANK_BYTES)

    def put(bank, tile, tile_bytes):
        off = bank * BANK_BYTES + tile * TILE_BYTES
        data[off:off + TILE_BYTES] = tile_bytes

    for k in range(8):
        put(k, 0, solid(1 + (k % 3)))
    put(0, 1, solid(2))
    put(0, 2, solid(3))
    put(0, 3, checker(1, 2))
    for k in range(8):
        put(64 + k, 0, solid(1 + ((k + 1) % 3)))
    put(64, 1, solid(3))
    put(64, 2, solid(1))
    put(64, 3, checker(2, 3))
    return bytes(data)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--test", action="store_true")
    ap.add_argument("--game", action="store_true")
    ap.add_argument("--wad", help="WAD path (with --texlist)")
    ap.add_argument("--texlist", help="texture slot list json from mapconv")
    ap.add_argument("--luts", help="output path for generated LUT .s")
    ap.add_argument("-o", "--out", required=True)
    args = ap.parse_args()

    if args.test:
        data = test_chr()
        with open(args.out, "wb") as f:
            f.write(data)
        print(f"wrote {args.out}: {len(data)} bytes ({len(data) // BANK_BYTES} banks)")
        return

    if args.wad:
        texlist = json.load(open(args.texlist))
        textures, tex_bins = wad_textures(args.wad, texlist)
        expected_flat = 60
    elif args.game:
        textures = [brick_texture(), stone_texture()]
        # synthetic textures: nominal warm brick / cool stone bins
        tex_bins = [
            {1: (210, 180, 140), 2: (150, 75, 40), 3: (80, 50, 35)},
            {1: (155, 155, 165), 2: (110, 115, 125), 3: (60, 65, 78)},
        ]
        expected_flat = 8
    else:
        ap.error("pass --test, --game, or --wad")
    ramp_of, bins_a, bins_b = split_ramps(tex_bins)
    bg_palettes = derive_palettes(bins_a, bins_b)

    data, st, sb, used, flat_bank = slice_banks(textures)
    # FLAT_BANK is a build-time constant in src/globals.inc — keep them locked
    assert flat_bank <= expected_flat, f"flat bank {flat_bank} > {expected_flat}"
    if flat_bank < expected_flat:   # pad so flats land exactly at expected_flat
        pad = (expected_flat - flat_bank) * BANK_BYTES
        data = data[:flat_bank * BANK_BYTES] + b"\0" * pad + data[flat_bank * BANK_BYTES:]
        flat_bank = expected_flat
    write_luts(args.luts or "assets/build/luts.s", st, sb, len(textures),
               bg_palettes, ramp_of)
    with open(args.out, "wb") as f:
        f.write(data)
    print(f"wrote {args.out}: {len(data)} bytes, {used} tiles, "
          f"{len(textures)} textures, flats at bank {flat_bank}")
    print("palettes: " + " | ".join(
        " ".join(f"{v:02X}" for v in bg_palettes[i*4:i*4+4]) for i in range(4)))


if __name__ == "__main__":
    main()
