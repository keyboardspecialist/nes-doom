#!/usr/bin/env python3
"""CHR-ROM generator for the NES Doom PoC.

--test mode (M1/M2): hand-built diagnostic banks (see test_chr below).

--game mode (M4/M5): 2 synthetic textures (brick, stone) -> banks 0-9,
  flats/status at bank 10.

--wad WAD --texlist texlist.json (E1M1): compose each named texture from the
  WAD, palette-aware quantization per 8px strip (luminance bins, per-strip
  ramp choice, ordered dither; the ramp bit rides slice_bank bit 7), same
  slice pipeline -> 5 banks per texture (per-class isotropic texel widths,
  CLASS_TW), flats at bank 5*ntex.

Slices: per (texture, height class, u-phase), an 8-px-wide column of the
64x64 source rescaled to H tiles, contiguous within one 4KB bank. LUT output
(luts.s): slice_tile[], slice_bank[] (ntex*SLICES_PER_TEX entries) +
tex_base_lo/hi[] (16-bit offsets) for pointer-based lookup in src/render.s.
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
# Per-class texel width per 8px column (power of 2 nearest 64/h): matches
# the class's vertical scale, so textures stay isotropic at every distance.
# Wide (minified) slices for far classes are box-filtered at bake time —
# proper mips, so distant walls no longer phase-crawl; narrow (magnified)
# slices for near classes stop the column-frequency repetition.
CLASS_TW = [64, 32, 32, 16, 16, 16, 16, 8, 8, 4, 4, 4, 4]
CLASS_PHASES = [64 // tw for tw in CLASS_TW]
BANKS_PER_TEX = 5
SLICES_PER_TEX = sum(CLASS_PHASES)


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


def _box_axis(n_src, n_dst):
    """Fractional box-filter weights: for each dest cell, the list of
    (src_index, weight) covering [i*n_src/n_dst, (i+1)*n_src/n_dst)."""
    spans = []
    for i in range(n_dst):
        a = i * n_src / n_dst
        b = (i + 1) * n_src / n_dst
        cells = []
        j = int(a)
        while j < b and j < n_src:
            w = min(b, j + 1) - max(a, j)
            if w > 1e-9:
                cells.append((j, w))
            j += 1
        spans.append(cells)
    return spans


def box_resample(rgb, w_dst, h_dst):
    """Area-average an RGB map rgb[y][x] to w_dst x h_dst (handles up- and
    downscale; upscale degenerates to replication)."""
    h_src, w_src = len(rgb), len(rgb[0])
    xs = _box_axis(w_src, w_dst)
    ys = _box_axis(h_src, h_dst)
    out = []
    for yc in ys:
        row = []
        for xc in xs:
            r = g = b = wt = 0.0
            for j, wy in yc:
                src = rgb[j]
                for i, wx in xc:
                    w = wy * wx
                    p = src[i]
                    r += p[0] * w
                    g += p[1] * w
                    b += p[2] * w
                    wt += w
            row.append((r / wt, g / wt, b / wt))
        out.append(row)
    return out


def wad_textures(wadpath, texlist):
    """Compose each named texture, box-filter to a 64x64 RGB map (area
    average — point sampling aliased thin details away), plus the
    luminance-binned chroma-weighted bin RGB per texture (drives ramp
    derivation, so colorful pixels outvote gray mortar/shadows)."""
    import wadlib
    wad = wadlib.Wad(wadpath)
    defs = wadlib.texture_defs(wad)
    pnames = wadlib._patch_names(wad)
    pal = wadlib.playpal(wad)
    out = []
    tex_bins = []
    thresholds = []
    for name in texlist:
        w, h, img = wadlib.compose_texture(wad, defs, pnames, name)
        src = [[pal[img[x][y]] for x in range(w)] for y in range(h)]
        rgbmap = box_resample(src, 64, 64)
        lums = sorted(_lum(p) for row in rgbmap for p in row)
        p33, p66 = lums[len(lums) // 3], lums[(2 * len(lums)) // 3]
        # brightest -> color 1 (top of the palette ramp), darkest -> 3
        sums = {1: [0, 0, 0, 0], 2: [0, 0, 0, 0], 3: [0, 0, 0, 0]}
        for row in rgbmap:
            for p in row:
                lm = _lum(p)
                c = 1 if lm >= p66 else (2 if lm >= p33 else 3)
                s = sums[c]
                wt = max(p) - min(p) + 1
                s[0] += p[0] * wt
                s[1] += p[1] * wt
                s[2] += p[2] * wt
                s[3] += wt
        out.append(rgbmap)
        tex_bins.append({c: (s[0] / max(s[3], 1), s[1] / max(s[3], 1),
                             s[2] / max(s[3], 1)) for c, s in sums.items()})
        thresholds.append((p33, p66))
    return out, tex_bins, thresholds


def _wdist(a, b):
    return (0.3 * (a[0] - b[0]) ** 2 + 0.59 * (a[1] - b[1]) ** 2
            + 0.11 * (a[2] - b[2]) ** 2)


def _lum(p):
    return 0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2]


def quantize_rows(rgb_rows, p33, p66, dither=True):
    """Quantize RGB rows to colors 1-3 by the texture's luminance
    thresholds (keeps relative contrast — raw nearest-RGB matching dies on
    dark Doom art), with an ordered dither toward the neighboring bin near
    a threshold. Runs at FINAL resolution so the dither pattern never
    moires through a rescale."""
    band = max(4.0, (p66 - p33) * 0.3)
    idx = []
    for y, row in enumerate(rgb_rows):
        irow = []
        for x, p in enumerate(row):
            lm = _lum(p)
            c = 1 if lm >= p66 else (2 if lm >= p33 else 3)
            if dither and (x ^ y) & 1:
                if c == 1 and lm < p66 + band:
                    c = 2
                elif c == 2 and lm >= p66 - band:
                    c = 1
                elif c == 2 and lm < p33 + band:
                    c = 3
                elif c == 3 and lm >= p33 - band:
                    c = 2
            irow.append(c)
        idx.append(irow)
    return idx


def strip_ramp_err(rgb_rows, p33, p66, ramp_rgbs):
    """Per-ramp fit error of one RGB strip: bin pixels by the texture
    thresholds, then compare each bin's chroma-weighted mean —
    luminance-scaled to the candidate color, the same trick ramp_base
    uses — against the ramp's NES colors."""
    sums = {1: [0.0, 0.0, 0.0, 0.0], 2: [0.0, 0.0, 0.0, 0.0],
            3: [0.0, 0.0, 0.0, 0.0]}
    for row in rgb_rows:
        for p in row:
            lm = _lum(p)
            c = 1 if lm >= p66 else (2 if lm >= p33 else 3)
            s = sums[c]
            wt = max(p) - min(p) + 1
            s[0] += p[0] * wt
            s[1] += p[1] * wt
            s[2] += p[2] * wt
            s[3] += wt
    errs = []
    for cols in ramp_rgbs:
        err = 0.0
        for c in (1, 2, 3):
            s = sums[c]
            if s[3] <= 0:
                continue
            rgb = (s[0] / s[3], s[1] / s[3], s[2] / s[3])
            nes = cols[c - 1]
            sc = _lum(nes) / max(_lum(rgb), 1.0)
            err += s[3] * _wdist((rgb[0] * sc, rgb[1] * sc, rgb[2] * sc), nes)
        errs.append(err)
    return errs


def texture_strips_wad(rgb_maps, thresholds, ramp_bases):
    """-> strips[ti] = ('rgb', rgbmap 64x64, ramps[8], p33, p66).
    Ramp coherence: the texture's majority ramp wins unless a strip prefers
    the other ramp by a wide margin (< 0.55x error), then a neighbor pass
    flips isolated deviants back — near-ties and lone strips follow the
    majority, so walls don't stripe; genuinely distinct features (silver
    panel runs in a tan wall) still switch. Zoomed 16-phase slices inherit
    the parent 8-texel strip's ramp."""
    ramp_rgbs = [[NES_PAL[v] for v in base] for base in ramp_bases]
    strips = []
    for rgbmap, (p33, p66) in zip(rgb_maps, thresholds):
        rows_of = [[rgbmap[y][p * 8:(p + 1) * 8] for y in range(64)]
                   for p in range(8)]
        errs = [strip_ramp_err(rows_of[p], p33, p66, ramp_rgbs)
                for p in range(8)]
        major = 0 if sum(e[0] for e in errs) <= sum(e[1] for e in errs) else 1
        ramps = []
        for p in range(8):
            ramp = major
            other = 1 - major
            if errs[p][other] < 0.55 * errs[p][major]:
                ramp = other
            ramps.append(ramp)
        # isolated deviant strips (both neighbors = majority) revert
        for p in range(8):
            if ramps[p] != major:
                left = ramps[p - 1] if p > 0 else major
                right = ramps[p + 1] if p < 7 else major
                if left == major and right == major:
                    ramps[p] = major
        # 16-texel ramp blocks: every class with tw <= 16 sees identical
        # ramp boundaries, so palette regions stay put as classes change
        # with distance (they used to pop at class transitions)
        blocks = [ramps[2 * b] if ramps[2 * b] == ramps[2 * b + 1] else major
                  for b in range(4)]
        ramps = [blocks[p >> 1] for p in range(8)]
        strips.append(("rgb", rgbmap, ramps, p33, p66))
    return strips


def texture_strips_indexed(index_maps, ramp_of):
    """--game path: textures are already 3-color index maps; every strip
    inherits the texture's ramp and keeps nearest-neighbor rescale."""
    return [("idx", tex, [ramp_of[ti]] * 8, 0, 0)
            for ti, tex in enumerate(index_maps)]


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


BACKDROP = 0x0F     # ceiling color (black): ceilings are BLANK tiles showing
                    # the backdrop, which lets shared edge tiles carry a
                    # "ceiling-colored" region under any wall palette. (Was
                    # $00 gray on paper, but the runtime always displayed
                    # black until the per-frame NMI palette load made the
                    # entry authoritative.)


def ramp_base(bins):
    """bins {1: rgb, 2: rgb, 3: rgb} -> 3 NES colors at fixed rows 3/2/1.

    Doom textures are dark overall, so raw nearest-color matching lands in
    NES row 0 and the light ramp dies. Instead: pin the bins to fixed rows
    and match only the HUE, comparing against the bin color scaled to each
    candidate's luminance. One hue column is chosen for the WHOLE ramp
    (summed over the three bins) — per-row independent matching produced
    incoherent ramps like yellow/gray/black."""
    rows = {1: 3, 2: 2, 3: 1}
    best_col, bd = 0, 1e18
    for col in range(13):               # cols 13-15 are blacker-than-black
        d = 0.0
        for c in (1, 2, 3):
            rgb = bins[c]
            lum = 0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2]
            nes = NES_PAL[(rows[c] << 4) | col]
            nlum = 0.299 * nes[0] + 0.587 * nes[1] + 0.114 * nes[2]
            s = nlum / max(lum, 1.0)
            d += (0.3 * (rgb[0] * s - nes[0]) ** 2
                  + 0.59 * (rgb[1] * s - nes[1]) ** 2
                  + 0.11 * (rgb[2] * s - nes[2]) ** 2)
        if d < bd:
            best_col, bd = col, d
    base = [(rows[c] << 4) | best_col for c in (1, 2, 3)]
    if best_col == 0:
        # NES $30 and $20 are both white: gray ramps use rows 2/1/0 so all
        # three stay distinct
        base = [v - 0x10 for v in base]
    return base


def derive_palettes(ramp_bases):
    """Two hue ramps x two light levels:
    palette 0/1 = ramp A light 0/1, palette 2/3 = ramp B light 0/1."""
    pals = []
    for base in ramp_bases:
        for light in range(2):
            pals.append(BACKDROP)
            for v in base:
                row, hue = v >> 4, v & 0x0F
                r = row - light
                pals.append(0x0F if r < 0 else (r << 4) | hue)
    return pals


def slice_banks(strips, max_cls, fixed_flat=None):
    """Prescale every (texture, class, phase) column into contiguous tiles.
    strips[ti] = (kind, texmap, ramps[8], p33, p66); the per-strip ramp
    rides bit 7 of the slice_bank byte (banks stay < 64, bits 6-7 free) so
    palette choice is per-slice at zero runtime cost.

    Texels per column follow CLASS_TW (isotropic per class): wide box-
    filtered slices for far classes (stable, mip-like), narrow magnified
    slices for near ones (no column-frequency repetition).

    'rgb' textures (WAD path) are box-filtered to the class size in RGB and
    quantized+dithered at final resolution — nearest decimation turned
    distant classes into noise. 'idx' textures (synthetic --game) keep
    nearest-neighbor rescale."""
    # wad path: variable banks per texture packed sequentially into 0-59
    # (classes above the texture's max_class are pruned -- unreachable by
    # construction, since span <= world height and vshift bounds the rest);
    # game path: fixed BANKS_PER_TEX stride.
    flat_bank = fixed_flat if fixed_flat is not None \
        else len(strips) * BANKS_PER_TEX
    banks = [bytearray() for _ in range(flat_bank + 1)]
    slice_tile, slice_bank = [], []
    bank = 0
    for ti, (kind, texmap, ramps, p33, p66) in enumerate(strips):
        if fixed_flat is None:
            bank = ti * BANKS_PER_TEX
        limit = flat_bank if fixed_flat is not None \
            else bank + BANKS_PER_TEX
        if fixed_flat is not None and ti > 0:
            bank += 1                    # each texture starts a fresh bank
        tex_bank0 = bank
        major = max(set(ramps), key=ramps.count)
        baked = {}                       # (class, phase) -> LUT entry pair
        for ci, h in enumerate(CLASSES):
            if ci > max_cls[ti]:
                # pruned: unreachable by construction; backstop points at
                # the texture's own top class (wrong scale beats garbage)
                mc = max_cls[ti]
                for p in range(CLASS_PHASES[ci]):
                    pm = p * CLASS_PHASES[mc] // CLASS_PHASES[ci]
                    t, b = baked[(mc, pm)]
                    slice_tile.append(t)
                    slice_bank.append(b)
                continue
            hpx = h * 8
            tw = CLASS_TW[ci]
            scaled = []
            if kind == "rgb":
                # box-filter every phase strip to the class size first, then
                # re-derive the luminance thresholds from the FILTERED pixels:
                # filtering compresses contrast toward the mean, and the
                # texture-global thresholds would classify everything into
                # the mid bin (distant walls went flat)
                for p in range(CLASS_PHASES[ci]):
                    rows = [texmap[y][p * tw:(p + 1) * tw] for y in range(64)]
                    scaled.append(box_resample(rows, 8, hpx))
                lums = sorted(_lum(px) for s in scaled for row in s
                              for px in row)
                cp33 = lums[len(lums) // 3]
                cp66 = lums[(2 * len(lums)) // 3]
            for p in range(CLASS_PHASES[ci]):
                # tw <= 16 aligns to the 16-texel ramp blocks; wider (far)
                # slices span several blocks and take the texture majority
                ramp = ramps[min(7, p * tw // 8)] if tw <= 16 else major
                if kind == "rgb":
                    col = quantize_rows(scaled[p], cp33, cp66)
                else:
                    x0 = p * tw
                    col = [[texmap[y * 64 // hpx][x0 + x * tw // 8]
                            for x in range(8)] for y in range(hpx)]
                if len(banks[bank]) // TILE_BYTES + h > BANK_TILES:
                    bank += 1
                    assert bank < limit, "texture slices overflowed the banks"
                entry = (len(banks[bank]) // TILE_BYTES, bank | (ramp << 7))
                baked[(ci, p)] = entry
                slice_tile.append(entry[0])
                slice_bank.append(entry[1])
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


def write_luts(path, slice_tile, slice_bank, ntex, bg_palettes, hud=None,
               sec_pal=None):
    bases = [min(t, 15) * SLICES_PER_TEX for t in range(16)]
    tables = [("slice_tile", slice_tile), ("slice_bank", slice_bank),
              ("tex_base_lo", [b & 0xFF for b in bases]),
              ("tex_base_hi", [b >> 8 for b in bases]),
              ("bg_palettes", bg_palettes)]
    if hud:
        tables += [("hud_nt", hud[0]), ("hud_ex", hud[1]),
                   ("hud_palettes", HUD_PALETTES)]
    if sec_pal:
        tables += [("sec_pal", sec_pal)]
    with open(path, "w") as f:
        f.write("; GENERATED by tools/tilegen.py — do not edit\n")
        f.write(".export slice_tile, slice_bank, tex_base_lo, tex_base_hi\n")
        f.write(".export bg_palettes\n")
        if hud:
            f.write(".export hud_nt, hud_ex, hud_palettes\n")
        if sec_pal:
            f.write(".export sec_pal\n")
        f.write('.segment "LUT00"\n')
        for name, vals in tables:
            f.write(f"{name}:\n")
            for i in range(0, len(vals), 16):
                f.write("    .byte " + ", ".join(f"${v:02X}" for v in vals[i:i+16]) + "\n")


HUD_ROWS = 5              # status bar: tile rows 20-24 = 40 px, 32 cols
HUD_BANK_PAL = None       # set by build_hud


# Dedicated HUD palette set, loaded by the line-160 IRQ (the status bar has
# its own 4 BG palettes; walls keep theirs above the split): gray panel,
# STTNUM red digits, flesh face, gold accents. Backdrop black = seam color.
HUD_PALETTES = [
    0x0F, 0x20, 0x10, 0x00,     # panel grays
    0x0F, 0x26, 0x16, 0x06,     # digit reds
    0x0F, 0x27, 0x17, 0x07,     # face flesh/browns
    0x0F, 0x28, 0x18, 0x08,     # gold/olive accents
]


def build_hud(wadpath, bg_palettes, hud_bank):
    """Compose the Doom status bar (STBAR + arms panel + face + baked
    placeholder digits), scale 320x40 -> 256x40, quantize each 8x8 cell
    against all 4 BG palettes (per-tile ExAttr palette choice; color 0 =
    the backdrop is usable here since the bar is opaque), dedup tiles.
    Returns (tiles bytes list, hud_nt[160], hud_ex[160])."""
    import wadlib
    wad = wadlib.Wad(wadpath)
    pal = wadlib.playpal(wad)
    W, H = 320, 40
    img = [[-1] * H for _ in range(W)]      # img[x][y], -1 = empty
    wadlib._draw_picture(wad, "STBAR", img, W, H, 0, 8)
    wadlib._draw_picture(wad, "STARMS", img, W, H, 104, 8)
    wadlib._draw_picture(wad, "STFST01", img, W, H, 143, 9)

    def digits(s, right_x, y):
        x = right_x
        for ch in reversed(s):
            name = "STTPRCNT" if ch == "%" else "STTNUM" + ch
            d = wad.lump(name)
            import struct
            pw = struct.unpack_from("<hhhh", d, 0)[0]
            x -= pw
            wadlib._draw_picture(wad, name, img, W, H, x, y)

    digits("50", 44, 11)                    # ammo
    digits("100%", 104, 11)                 # health
    digits("0%", 235, 11)                   # armor

    # RGB canvas (empty -> near-black), box-filter 320x40 -> 256x40
    rgb = [[pal[img[x][y]] if img[x][y] >= 0 else (12, 12, 12)
            for x in range(W)] for y in range(H)]
    rgb = box_resample(rgb, 256, H)

    # the 4 HUD palettes as RGB (color 0 = backdrop included)
    pals = [[NES_PAL[HUD_PALETTES[p * 4 + c] & 0x3F] for c in range(4)]
            for p in range(4)]
    tiles, tmap = [], {}
    hud_nt, hud_ex = [], []
    for row in range(HUD_ROWS):
        for col in range(32):
            cell = [[rgb[row * 8 + y][col * 8 + x] for x in range(8)]
                    for y in range(8)]
            best = None
            # face region (320-space x 143-167 -> cols 14-16): flesh/gray
            # only, or hair fringes grab the olive accent and read green
            cand = (0, 2) if 14 <= col <= 16 else (0, 1, 2, 3)
            for pi in cand:
                cols = pals[pi]
                err = 0.0
                idx = []
                for y, r in enumerate(cell):
                    irow = []
                    for x, px in enumerate(r):
                        d = sorted((_wdist(px, c), i)
                                   for i, c in enumerate(cols))
                        (d1, c1), (d2, c2) = d[0], d[1]
                        if d1 + d2 > 0 and d1 / (d1 + d2) > 0.38 \
                                and (x ^ y) & 1:
                            c1 = c2
                            d1 = d2
                        err += d1
                        irow.append(c1)
                    idx.append(irow)
                if best is None or err < best[0]:
                    best = (err, pi, idx)
            _, pi, idx = best
            t = encode_tile(idx)
            if t not in tmap:
                tmap[t] = len(tiles)
                tiles.append(t)
            hud_nt.append(tmap[t])
            hud_ex.append(hud_bank | (pi << 6))
    assert len(tiles) <= 256, f"HUD needs {len(tiles)} tiles"
    return tiles, hud_nt, hud_ex


def edge_bank():
    """128 sloped silhouette tiles (bank 62, wad build): boundary height
    ramps linearly a->b pixels across the tile. Tiles 0-63 = top boundary
    (wall color 2 rising from the tile bottom, backdrop 0 above -- the
    backdrop IS the ceiling color); 64-127 = bottom boundary (wall from the
    tile top, floor color 3 below). Flat a==b cases subsume the old 14
    per-column edge tiles; the ramp kills the 8px silhouette stairstep."""
    tiles = []
    for top in (True, False):
        for a in range(8):
            for b in range(8):
                pix = [[0] * 8 for _ in range(8)]
                for x in range(8):
                    k = int(round(a + (b - a) * (x + 0.5) / 8.0))
                    for y in range(8):
                        if top:
                            pix[y][x] = 2 if y >= 8 - k else 0
                        else:
                            pix[y][x] = 2 if y < k else 3
                tiles.append(encode_tile(pix))
    return tiles


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
        texinfo = json.load(open(args.texlist))
        texlist = texinfo["slots"]
        sec_tex = texinfo["sec_tex"]
        names = [t["name"] for t in texlist]
        max_cls = [t["max_class"] for t in texlist]
        rgb_maps, tex_bins, thresholds = wad_textures(args.wad, names)
        expected_flat = 60      # texture banks 0-59; FLAT_BANK in globals.inc
    elif args.game:
        index_maps = [brick_texture(), stone_texture()]
        # synthetic textures: nominal warm brick / cool stone bins
        tex_bins = [
            {1: (210, 180, 140), 2: (150, 75, 40), 3: (80, 50, 35)},
            {1: (155, 155, 165), 2: (110, 115, 125), 3: (60, 65, 78)},
        ]
        expected_flat = 2 * BANKS_PER_TEX
    else:
        ap.error("pass --test, --game, or --wad")
    ramp_of, bins_a, bins_b = split_ramps(tex_bins)
    ramp_bases = [ramp_base(bins_a), ramp_base(bins_b)]
    bg_palettes = derive_palettes(ramp_bases)

    if args.wad:
        strips = texture_strips_wad(rgb_maps, thresholds, ramp_bases)
    else:
        strips = texture_strips_indexed(index_maps, ramp_of)
        max_cls = [len(CLASSES) - 1] * len(strips)
    data, st, sb, used, flat_bank = slice_banks(
        strips, max_cls, fixed_flat=60 if args.wad else None)
    # FLAT_BANK is a build-time constant in src/globals.inc — keep them locked
    assert flat_bank <= expected_flat, f"flat bank {flat_bank} > {expected_flat}"
    if flat_bank < expected_flat:   # pad so flats land exactly at expected_flat
        pad = (expected_flat - flat_bank) * BANK_BYTES
        data = data[:flat_bank * BANK_BYTES] + b"\0" * pad + data[flat_bank * BANK_BYTES:]
        flat_bank = expected_flat
    sec_pal = None
    if args.wad:
        # per-sector palette sets: each sector derives its own warm/cool
        # ramp pair from ITS textures (chroma-weighted bins); the engine
        # loads the camera sector's 16 bytes during vblank every frame.
        # Quantization is luminance-binned with hue purely in the palette,
        # so the recolor stays coherent (Doom-colormap style).
        sec_pal = []
        for stex in sec_tex:
            idxs = [int(k) for k in stex.keys()]
            if not idxs:
                sec_pal.extend(bg_palettes)
                continue
            sub_bins = [tex_bins[i] for i in idxs]
            if len(sub_bins) == 1:
                bases = [ramp_base(sub_bins[0])] * 2
            else:
                _, ba, bb = split_ramps(sub_bins)
                bases = [ramp_base(ba), ramp_base(bb)]
            sec_pal.extend(derive_palettes(bases))
    hud = None
    if args.wad:
        tiles, hud_nt, hud_ex = build_hud(args.wad, bg_palettes,
                                          flat_bank + 1)
        bank = bytearray()
        for t in tiles:
            bank.extend(t)
        data = data + bytes(bank.ljust(BANK_BYTES, b"\0"))
        hud = (hud_nt, hud_ex)
        print(f"HUD: {len(tiles)} unique tiles in bank {flat_bank + 1}")
        ebank = bytearray()
        for t in edge_bank():
            ebank.extend(t)
        data = data + bytes(ebank.ljust(BANK_BYTES, b"\0"))
        print(f"edges: 128 sloped tiles in bank {flat_bank + 2}")
    write_luts(args.luts or "assets/build/luts.s", st, sb, len(strips),
               bg_palettes, hud, sec_pal)
    with open(args.out, "wb") as f:
        f.write(data)
    print(f"wrote {args.out}: {len(data)} bytes, {used} tiles, "
          f"{len(strips)} textures, flats at bank {flat_bank}")
    print("palettes: " + " | ".join(
        " ".join(f"{v:02X}" for v in bg_palettes[i*4:i*4+4]) for i in range(4)))


if __name__ == "__main__":
    main()
