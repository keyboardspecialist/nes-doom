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
    """Compose + quantize each named texture to a 64x64 map of colors 1-3."""
    import wadlib
    wad = wadlib.Wad(wadpath)
    defs = wadlib.texture_defs(wad)
    pnames = wadlib._patch_names(wad)
    pal = wadlib.playpal(wad)
    lum = [0.299 * r + 0.587 * g + 0.114 * b for (r, g, b) in pal]
    out = []
    for name in texlist:
        w, h, img = wadlib.compose_texture(wad, defs, pnames, name)
        # sample to 64x64 (tile smaller textures, compress taller/wider)
        smp = [[img[(x * w) // 64][(y * h) // 64] for x in range(64)]
               for y in range(64)]
        lums = sorted(lum[p] for row in smp for p in row)
        p33, p66 = lums[len(lums) // 3], lums[(2 * len(lums)) // 3]
        # brightest -> color 1 (top of the palette ramp), darkest -> 3
        tex = [[1 if lum[p] >= p66 else (2 if lum[p] >= p33 else 3)
                for p in row] for row in smp]
        out.append(tex)
    return out


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
    fb.extend(solid(1))          # tile 0: ceiling
    fb.extend(solid(2))          # tile 1
    fb.extend(solid(3))          # tile 2: floor
    fb.extend(checker(1, 2))     # tile 3: status bar
    data = bytearray()
    for b in banks:
        data.extend(b.ljust(BANK_BYTES, b"\0"))
    used = sum(len(b) // TILE_BYTES for b in banks)
    return bytes(data), slice_tile, slice_bank, used, flat_bank


def write_luts(path, slice_tile, slice_bank, ntex):
    bases = [min(t, 15) * SLICES_PER_TEX for t in range(16)]
    with open(path, "w") as f:
        f.write("; GENERATED by tools/tilegen.py — do not edit\n")
        f.write(".export slice_tile, slice_bank, tex_base_lo, tex_base_hi\n")
        f.write('.segment "LUT00"\n')
        for name, vals in (("slice_tile", slice_tile), ("slice_bank", slice_bank),
                           ("tex_base_lo", [b & 0xFF for b in bases]),
                           ("tex_base_hi", [b >> 8 for b in bases])):
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
        textures = wad_textures(args.wad, texlist)
        expected_flat = 60
    elif args.game:
        textures = [brick_texture(), stone_texture()]
        expected_flat = 8
    else:
        ap.error("pass --test, --game, or --wad")

    data, st, sb, used, flat_bank = slice_banks(textures)
    # FLAT_BANK is a build-time constant in src/globals.inc — keep them locked
    assert flat_bank <= expected_flat, f"flat bank {flat_bank} > {expected_flat}"
    if flat_bank < expected_flat:   # pad so flats land exactly at expected_flat
        pad = (expected_flat - flat_bank) * BANK_BYTES
        data = data[:flat_bank * BANK_BYTES] + b"\0" * pad + data[flat_bank * BANK_BYTES:]
        flat_bank = expected_flat
    write_luts(args.luts or "assets/build/luts.s", st, sb, len(textures))
    with open(args.out, "wb") as f:
        f.write(data)
    print(f"wrote {args.out}: {len(data)} bytes, {used} tiles, "
          f"{len(textures)} textures, flats at bank {flat_bank}")


if __name__ == "__main__":
    main()
