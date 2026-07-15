#!/usr/bin/env python3
"""Map converter v2 — emits map.s (segment LUT01, the $A000 window).

Two modes:
  (default)      hand-authored 3-sector micro-map (M5)
  --wad WAD MAP  convert a real Doom map (BSP comes from the WAD): rescale,
                 split long segs, trim to a seg/byte budget by sector-BFS from
                 the player start, splice the BSP over kept subsectors, and
                 select wall textures (slot list -> texlist.json).
  --full         retain the complete map and emit banked 12-byte seg records
                 with 16-bit vertex endpoints.

Engine data formats (must match src/bsp.s + src/render.s):
  vertex   4B  x, y                       s11.4 words
  seg     10B  v1, vphase, v2, vphase_low, ulen, u0, tex, tex_low,
                front, back ($FF = solid). Full maps append v1_hi, v2_hi.
  node    16B  px, py, pdx, pdy (s11.4), c0_idx, c0_isleaf, c1_idx, c1_isleaf,
               bbox x1,y1,x2,y2 (page bytes = s11.4 >> 8, subtree union)
               side 0 (child 0) when (x-px)*pdy - (y-py)*pdx >= 0
               (identical to Doom's R_PointOnSide -> children keep their order)
  arrays: ss_first_lo/hi, ss_count, ss_sector; sec_floor, sec_ceil (signed
          bytes, absolute), sec_light (0-3)
  consts: MAP_ROOT_NODE, PLAYER_PX/PY/ANG, EYE_REL
"""
import argparse
import json
import math
import struct


# ---------------------------------------------------------------- emission --
def byte_rows(vals):
    return "\n".join(
        "    .byte " + ", ".join(f"${v & 0xFF:02X}" for v in vals[i:i+16])
        for i in range(0, len(vals), 16)) or "    ; empty"


def words(v):
    v = int(v) & 0xFFFF
    return [v & 0xFF, v >> 8]


def emit_map(path, verts, segs, nodes, subsectors, sectors, root, player,
             eye_rel, reject=None, things=None, full=False):
    vdata = []
    for (x, y) in verts:
        vdata += words(x) + words(y)
    sdata = []
    for seg in segs:
        v1, v2, ulen, u0, tex, texl, front, back = seg[:8]
        vphase = seg[8] if len(seg) > 8 else 0
        vphase_l = seg[9] if len(seg) > 9 else 0
        sdata += [v1 & 0xFF, vphase, v2 & 0xFF, vphase_l]
        sdata += [ulen & 0xFF, u0 & 0xFF, tex, texl, front,
                  0xFF if back is None else back]
        if full:
            sdata += [(v1 >> 8) & 0xFF, (v2 >> 8) & 0xFF]
    ndata = []
    for (px, py, pdx, pdy, c0, c1, bbox) in nodes:
        ndata += words(px) + words(py) + words(pdx) + words(pdy)
        ndata += [c0[0], 1 if c0[1] else 0, c1[0], 1 if c1[1] else 0]
        bx1, by1, bx2, by2 = bbox
        ndata += [(bx1 >> 8) & 0xFF, (by1 >> 8) & 0xFF,
                  ((bx2 + 255) >> 8) & 0xFF, ((by2 + 255) >> 8) & 0xFF]
    ss_first = [s[0] for s in subsectors]
    ss_count = [s[1] for s in subsectors]
    ss_sector = [s[2] for s in subsectors]
    thing_groups = things if things is not None else [[] for _ in subsectors]
    assert len(thing_groups) == len(subsectors)
    ss_thing_first = []
    ss_thing_count = []
    thing_x, thing_y, thing_kind = [], [], []
    monster_thing_idx, monster_spawn_ss = [], []
    for ss_index, group in enumerate(thing_groups):
        ss_thing_first.append(len(thing_kind))
        ss_thing_count.append(len(group))
        for x, y, kind in group:
            if kind == 4:
                monster_thing_idx.append(len(thing_kind))
                monster_spawn_ss.append(ss_index)
            thing_x.append(x)
            thing_y.append(y)
            thing_kind.append(kind)
    # per-subsector bbox (page bytes) — leaf-level culling is much tighter
    # than the node unions
    ss_bb = []
    for (first, count, _) in subsectors:
        pts = []
        for s in segs[first:first + count]:
            pts.append(verts[s[0]])
            pts.append(verts[s[1]])
        x1 = min(p[0] for p in pts) >> 8
        y1 = min(p[1] for p in pts) >> 8
        x2 = (max(p[0] for p in pts) + 255) >> 8
        y2 = (max(p[1] for p in pts) + 255) >> 8
        ss_bb.append((x1, y1, x2, y2))

    rowb = (len(sectors) + 7) // 8
    rej = bytearray(rowb * len(sectors))
    if reject:
        for i in range(len(sectors)):
            for j in range(len(sectors)):
                if reject(i, j):
                    rej[i * rowb + (j >> 3)] |= 1 << (j & 7)

    # LUT01 also holds sector palettes, sparse V-half tables, and generated
    # weapon/world metasprite data. Reserve enough for the enlarged close
    # enemy frames so picture-dependent pattern dedup cannot affect map trim.
    sprite_lut_reserve = 1280
    total = (len(vdata) + len(sdata) + len(ndata) + 8 * len(subsectors)
             + 3 * len(sectors) + len(rej) + 16 * len(sectors) + 736
             + 2 * len(subsectors) + 5 * len(thing_kind)
             + 2 * len(monster_thing_idx)
             + sprite_lut_reserve)
    if not full:
        assert total <= 8100, (f"map and sector palettes {total}B overflow "
                               "the 8KB LUT01 bank")
    assert len(nodes) <= 255 and len(subsectors) <= 255 and len(sectors) <= 254
    assert len(thing_kind) <= MAX_RUNTIME_THINGS
    assert len(monster_thing_idx) <= MAX_RUNTIME_MONSTERS
    assert all(v <= 255 for v in ss_thing_first + ss_thing_count)
    if full:
        assert len(verts) <= 0xFFFF and len(segs) <= 0xFFFF
    else:
        # The trimmed engine caches every vertex by its byte-sized index.
        assert len(verts) <= 256 and len(segs) <= 800

    # camera clamp bounds (hi-byte compares in update_cam), 32 units inside
    xs = [v[0] for v in verts]
    ys = [v[1] for v in verts]
    pxmin_h = (min(xs) + 32 * 16) >> 8
    pxmax_h = (max(xs) - 32 * 16) >> 8
    pymin_h = (min(ys) + 32 * 16) >> 8
    pymax_h = (max(ys) - 32 * 16) >> 8

    px, py, ang = player
    with open(path, "w") as f:
        f.write("; GENERATED by tools/mapconv.py — do not edit\n")
        if full:
            f.write(".export map_verts, map_segs0, map_segs1, map_nodes\n")
            f.write(".export SEG_BANK_SPLIT : absolute\n")
            f.write("SEG_BANK_SPLIT = 682\n")
        else:
            f.write(".export map_verts, map_segs, map_nodes\n")
        f.write(".export ss_first_lo, ss_first_hi, ss_count, ss_sector\n")
        f.write(".export ss_bx1, ss_by1, ss_bx2, ss_by2\n")
        f.write(".export ss_thing_first, ss_thing_count\n")
        f.write(".export thing_x_lo, thing_x_hi, thing_y_lo, thing_y_hi, thing_kind\n")
        f.write(".export monster_thing_idx, monster_spawn_ss\n")
        f.write(".export sec_floor, sec_ceil, sec_light\n")
        for name, val in (("MAP_ROOT_NODE", root),
                          ("PLAYER_PX", int(px) & 0xFFFF),
                          ("PLAYER_PY", int(py) & 0xFFFF),
                          ("PLAYER_ANG", int(ang) & 0xFFFF),
                          ("EYE_REL", eye_rel),
                          ("MAP_THING_COUNT", len(thing_kind)),
                          ("MONSTER_COUNT", len(monster_thing_idx)),
                          ("REJECT_ROWB", rowb),
                          ("PX_MIN_H", pxmin_h), ("PX_MAX_H", pxmax_h),
                          ("PY_MIN_H", pymin_h), ("PY_MAX_H", pymax_h)):
            f.write(f".export {name} : absolute\n{name} = {val}\n")
        f.write(".export reject_tbl\n")
        if full:
            split = 682 * 12
            assert len(sdata[:split]) <= 8192 and len(sdata[split:]) <= 8192
            assert len(vdata) + len(ndata) <= 8192
            f.write('.segment "MAPSEG0"\n')
            f.write(f"map_segs0:\n{byte_rows(sdata[:split])}\n")
            f.write('.segment "MAPSEG1"\n')
            f.write(f"map_segs1:\n{byte_rows(sdata[split:])}\n")
            f.write('.segment "MAPGEOM"\n')
            f.write(f"map_verts:\n{byte_rows(vdata)}\n")
            f.write(f"map_nodes:\n{byte_rows(ndata)}\n")
            geometry = ()
        else:
            geometry = (("map_verts", vdata), ("map_segs", sdata),
                        ("map_nodes", ndata))
        f.write('.segment "LUT01"\n')
        for name, vals in geometry + (
            ("ss_first_lo", [v & 0xFF for v in ss_first]),
            ("ss_first_hi", [v >> 8 for v in ss_first]),
            ("ss_count", ss_count), ("ss_sector", ss_sector),
            ("ss_bx1", [b[0] for b in ss_bb]), ("ss_by1", [b[1] for b in ss_bb]),
            ("ss_bx2", [b[2] for b in ss_bb]), ("ss_by2", [b[3] for b in ss_bb]),
            ("ss_thing_first", ss_thing_first),
            ("ss_thing_count", ss_thing_count),
            ("thing_x_lo", [v & 0xFF for v in thing_x]),
            ("thing_x_hi", [(v >> 8) & 0xFF for v in thing_x]),
            ("thing_y_lo", [v & 0xFF for v in thing_y]),
            ("thing_y_hi", [(v >> 8) & 0xFF for v in thing_y]),
            ("thing_kind", thing_kind),
            ("monster_thing_idx", monster_thing_idx),
            ("monster_spawn_ss", monster_spawn_ss),
            ("sec_floor", [v & 0xFF for v in [s[0] for s in sectors]]),
            ("sec_ceil", [v & 0xFF for v in [s[1] for s in sectors]]),
            ("sec_light", [s[2] for s in sectors]),
            ("reject_tbl", list(rej)),
        ):
            f.write(f"{name}:\n{byte_rows(vals)}\n")
    print(f"wrote {path}: {len(verts)} verts, {len(segs)} segs, "
          f"{len(nodes)} nodes, {len(subsectors)} ss, {len(sectors)} sectors, "
          f"{len(thing_kind)} things, {total}B")


# ---------------------------------------------------------------- micro map --
EYE_MICRO = 41
MICRO_SECTORS = [(0, 128, 0), (0, 96, 2), (16, 128, 1)]  # floor, ceil, light


def m_seg(v1, v2, tex, front, back=None):
    ln = abs(v2[0] - v1[0]) + abs(v2[1] - v1[1])
    assert 0 < ln <= 255
    return (v1, v2, ln, 0, tex, tex, front, back)


MICRO_LEAVES = [
    (2, [  # L0: room B
        m_seg((576, 224), (576, 320), 0, 2),
        m_seg((576, 64), (576, 160), 0, 2),
        m_seg((576, 160), (576, 224), 0, 2, 1),
        m_seg((576, 320), (768, 320), 0, 2),
        m_seg((768, 320), (768, 192), 0, 2),
        m_seg((768, 192), (768, 64), 0, 2),
        m_seg((768, 64), (576, 64), 0, 2),
    ]),
    (1, [  # L1: corridor
        m_seg((448, 224), (576, 224), 1, 1),
        m_seg((576, 160), (448, 160), 1, 1),
        m_seg((448, 160), (448, 224), 1, 1, 0),
        m_seg((576, 224), (576, 160), 1, 1, 2),
    ]),
    (0, [  # L2: room A north
        m_seg((64, 224), (64, 320), 0, 0),
        m_seg((64, 320), (256, 320), 0, 0),
        m_seg((256, 320), (448, 320), 0, 0),
        m_seg((448, 320), (448, 224), 0, 0),
        m_seg((288, 224), (224, 224), 1, 0),
    ]),
    (0, [  # L3: room A west
        m_seg((64, 64), (64, 224), 0, 0),
        m_seg((224, 64), (64, 64), 0, 0),
        m_seg((224, 224), (224, 160), 1, 0),
    ]),
    (0, [  # L4: pillar-south strip
        m_seg((224, 160), (288, 160), 1, 0),
        m_seg((288, 64), (224, 64), 0, 0),
    ]),
    (0, [  # L5: room A east
        m_seg((288, 160), (288, 224), 1, 0),
        m_seg((448, 160), (448, 64), 0, 0),
        m_seg((448, 224), (448, 160), 0, 0, 1),
        m_seg((448, 64), (288, 64), 0, 0),
    ]),
]

MICRO_NODES = [  # px, py, pdx, pdy, child0 (cross>=0), child1; L = leaf
    (448, 64, 0, 256, ("N", 1), ("N", 2)),
    (576, 64, 0, 256, ("L", 0), ("L", 1)),
    (64, 224, 256, 0, ("N", 3), ("L", 2)),
    (224, 64, 0, 256, ("N", 4), ("L", 3)),
    (288, 64, 0, 256, ("L", 5), ("L", 4)),
]


def build_micro():
    verts = []
    vmap = {}

    def vid(p):
        key = (p[0] * 16, p[1] * 16)
        if key not in vmap:
            vmap[key] = len(verts)
            verts.append(key)
        return vmap[key]

    segs = []
    subsectors = []
    for (sector, leaf) in MICRO_LEAVES:
        first = len(segs)
        for (v1, v2, ulen, u0, tex, texl, front, back) in leaf:
            segs.append((vid(v1), vid(v2), ulen, u0, tex, texl, front, back))
        subsectors.append((first, len(leaf), sector))
    nodes = []
    whole = (0, 0, 800 * 16, 400 * 16)   # tiny map: whole-map bbox everywhere
    for (px, py, pdx, pdy, c0, c1) in MICRO_NODES:
        nodes.append((px * 16, py * 16, pdx * 16, pdy * 16,
                      (c0[1], c0[0] == "L"), (c1[1], c1[0] == "L"), whole))
    player = (256 * 16, 128 * 16, 0)
    emit_map_args = (verts, segs, nodes, subsectors, MICRO_SECTORS, 0,
                     player, EYE_MICRO)
    return emit_map_args


# ------------------------------------------------------------------ WAD map --
SCALE = 0.4          # world units multiplier (keeps s11.4 deltas in int16)
EYE_WAD = round(41 * SCALE)
THING_SKILL_FLAG = 0x02  # medium, until runtime skill selection exists
MAX_RUNTIME_THINGS = 64
MAX_RUNTIME_MONSTERS = 8
# texture slots are budget-driven (banks 0-59; flats fixed at 60): see
# the selection loop in convert_wad
BYTE_BUDGET = 7900


def vertical_phase(kind, front_floor, front_ceil, back_floor, back_ceil,
                   tex_height, row_offset, flags):
    """Return Doom's wall V origin normalized to one native texture period."""
    if kind == "solid":
        anchor = (front_floor + tex_height
                  if flags & 0x0010 else front_ceil)
        top = front_ceil
    elif kind == "upper":
        anchor = (front_ceil
                  if flags & 0x0008 else back_ceil + tex_height)
        top = front_ceil
    elif kind == "lower":
        anchor = front_ceil if flags & 0x0010 else back_floor
        top = back_floor
    else:
        raise ValueError(f"unknown wall kind: {kind}")
    return ((anchor + row_offset - top) % tex_height) * 256 // tex_height


def convert_wad(wadpath, mapname, full=False):
    try:
        import wadlib
    except ModuleNotFoundError:
        from tools import wadlib
    wad = wadlib.Wad(wadpath)
    m = wadlib.parse_map(wad, mapname)
    texdefs = wadlib.texture_defs(wad)

    lines = m["linedefs"]
    sides = m["sidedefs"]
    wverts = m["vertexes"]

    # --- raw segs grouped by subsector, with texture names ---
    def seg_obj(si):
        v1, v2, ang, ld, direction, ofs = m["segs"][si]
        l = lines[ld]
        sr, sl = l[5], l[6]
        fside = sr if direction == 0 else sl
        bside = sl if direction == 0 else sr
        fs = sides[fside]
        back = None
        if bside != 0xFFFF and bside != -1:
            back = sides[bside][5]
        x1, y1 = wverts[v1]
        x2, y2 = wverts[v2]
        ulen = max(1, round(math.hypot(x2 - x1, y2 - y1)))
        u0 = (ofs + fs[0]) & 0xFF
        up, lo, mid = fs[2], fs[3], fs[4]
        if back is None:
            tex = mid if mid != "-" else (up if up != "-" else lo)
            texl = tex
        else:
            tex = up if up != "-" else (mid if mid != "-" else lo)
            texl = lo if lo != "-" else tex
        return {"p1": (x1, y1), "p2": (x2, y2), "ulen": ulen, "u0": u0,
                "tex": tex, "texl": texl, "front": fs[5], "back": back,
                "flags": l[2], "rowoff": fs[1]}

    ss_segs = []
    for (count, first) in m["ssectors"]:
        ss_segs.append([seg_obj(first + i) for i in range(count)])

    # --- split segs longer than 255 texels ---
    for lst in ss_segs:
        out = []
        for s in lst:
            k = (s["ulen"] + 254) // 255
            if k == 1:
                out.append(s)
                continue
            (x1, y1), (x2, y2) = s["p1"], s["p2"]
            for i in range(k):
                t0, t1 = i / k, (i + 1) / k
                piece = dict(s)
                piece["p1"] = (x1 + (x2 - x1) * t0, y1 + (y2 - y1) * t0)
                piece["p2"] = (x1 + (x2 - x1) * t1, y1 + (y2 - y1) * t1)
                piece["ulen"] = max(1, round(s["ulen"] / k))
                piece["u0"] = (s["u0"] + round(s["ulen"] * t0)) & 0xFF
                out.append(piece)
        lst[:] = out

    ss_sector = [lst[0]["front"] if lst else 0 for lst in ss_segs]

    # --- player start + its sector (walk the WAD BSP) ---
    start = next(t for t in m["things"] if t[3] == 1)
    sx, sy, sang = start[0], start[1], start[2]

    def point_ss(x, y):
        n = len(m["nodes"]) - 1
        while True:
            nd = m["nodes"][n]
            px, py, pdx, pdy = nd[0], nd[1], nd[2], nd[3]
            side = 0 if (x - px) * pdy - (y - py) * pdx >= 0 else 1
            child = nd[12 + side]
            if child & 0x8000:
                return child & 0x7FFF
            n = child
        return n

    start_sec = ss_sector[point_ss(sx, sy)]

    # --- sector BFS trim to byte budget ---
    adj = {}
    for l in lines:
        sr, sl = l[5], l[6]
        if sr != 0xFFFF and sl != 0xFFFF and sr != -1 and sl != -1:
            a, b = sides[sr][5], sides[sl][5]
            adj.setdefault(a, set()).add(b)
            adj.setdefault(b, set()).add(a)

    def cost(kept):
        ss_k = [i for i, s in enumerate(ss_sector) if s in kept]
        nseg = sum(len(ss_segs[i]) for i in ss_k)
        nv = 2 * nseg  # upper bound before dedupe
        nn = len(m["nodes"])  # upper bound
        return 4 * nv + 10 * nseg + 12 * nn + 4 * len(ss_k) + 3 * len(kept)

    if full:
        kept = set(range(len(m["sectors"])))
    else:
        kept = {start_sec}
        frontier = [start_sec]
        while frontier:
            nxt = []
            for s in frontier:
                for t in sorted(adj.get(s, ())):
                    if t in kept:
                        continue
                    trial = kept | {t}
                    if cost(trial) > BYTE_BUDGET:
                        continue
                    kept.add(t)
                    nxt.append(t)
            frontier = nxt

    kept_ss = [i for i, s in enumerate(ss_sector) if s in kept and ss_segs[i]]
    kept_ss_set = set(kept_ss)

    # --- splice BSP over kept subsectors ---
    new_nodes = []

    def splice(child, isleaf):
        if isleaf:
            return (child, True) if child in kept_ss_set else None
        nd = m["nodes"][child]
        c0 = splice(nd[12] & 0x7FFF, bool(nd[12] & 0x8000))
        c1 = splice(nd[13] & 0x7FFF, bool(nd[13] & 0x8000))
        if c0 is None and c1 is None:
            return None
        if c0 is None:
            return c1
        if c1 is None:
            return c0
        # subtree bbox = union of the WAD's per-child boxes (top,bot,left,right)
        bb = (min(nd[6], nd[10]), min(nd[5], nd[9]),
              max(nd[7], nd[11]), max(nd[4], nd[8]))  # xmin, ymin, xmax, ymax
        new_nodes.append((nd[0], nd[1], nd[2], nd[3], c0, c1, bb))
        return (len(new_nodes) - 1, False)

    root_ref = splice(len(m["nodes"]) - 1, False)
    assert root_ref and not root_ref[1], "degenerate map after trim"

    # --- renumber subsectors/sectors, transform coords, dedupe verts ---
    ss_renum = {old: i for i, old in enumerate(kept_ss)}
    sec_renum = {old: i for i, old in enumerate(sorted(kept))}

    # translate to all-positive coordinates (the engine's camera clamp and
    # the micro-map convention assume positive space), 64-unit margin
    minx = min(v[0] for v in wverts)
    maxx = max(v[0] for v in wverts)
    miny = min(v[1] for v in wverts)
    maxy = max(v[1] for v in wverts)
    cx = minx - 64 / SCALE
    cy = miny - 64 / SCALE
    assert (maxx - cx) * SCALE < 2000 and (maxy - cy) * SCALE < 2000

    def s114(wx, wy):
        return (round((wx - cx) * SCALE * 16), round((wy - cy) * SCALE * 16))

    verts = []
    vmap = {}

    def vid(p):
        key = s114(p[0], p[1])
        if key not in vmap:
            assert -32768 <= key[0] <= 32767 and -32768 <= key[1] <= 32767
            vmap[key] = len(verts)
            verts.append(key)
        return vmap[key]

    # --- texture slots: budget-driven with per-texture class pruning ---
    # A wall part's max screen span is bounded by its world height
    # (span = 16h/z, near clip z = 16 => span_max = h units), so short
    # textures never reach tall height classes and skip baking them.
    from collections import Counter
    try:
        from tilegen import CLASSES as TG_CLASSES, CLASS_PHASES
    except ModuleNotFoundError:
        from tools.tilegen import CLASSES as TG_CLASSES, CLASS_PHASES
    texcount = Counter()
    texh = {}
    for i in kept_ss:
        for s in ss_segs[i]:
            back_kept = s["back"] is not None and s["back"] in kept
            ff, fc, _ = m["sectors"][s["front"]]
            if back_kept:
                bf, bc, _ = m["sectors"][s["back"]]
                parts = [(s["tex"], fc - bc), (s["texl"], bf - ff)]
            else:
                parts = [(s["tex"], fc - ff)]
            for t, h in parts:
                if t and t != "-":
                    texcount[t] += 1
                    hs = max(1, round(texdefs[t][1] * SCALE))
                    assert hs <= 255, f"texture {t} period {hs} exceeds one byte"
                    texh[t] = max(texh.get(t, 1), hs)

    def max_class(h):
        span = min(240, h)
        while span > 20:                 # engine vshift reduction
            span = (span + 1) >> 1
        for ci in range(len(TG_CLASSES)):
            if TG_CLASSES[ci] >= span:
                return ci
        return len(TG_CLASSES) - 1

    def bank_cost(mc):
        banks, used = 1, 0
        for ci in range(mc + 1):
            h = TG_CLASSES[ci]
            for _ in range(CLASS_PHASES[ci]):
                if used + h > 256:
                    banks += 1
                    used = 0
                used += h
        return banks

    slots, used_banks, variant_tiles = [], 0, 0
    for t, _ in texcount.most_common():
        mc = max_class(texh[t])
        cost = bank_cost(mc)
        slot_index = len(slots)
        variant_cost = 192 if mc >= 10 else 0       # 16 phases * 12 rows
        if slot_index in {0, 2, 3, 4, 5, 6, 7} and mc >= 11:
            variant_cost += 224                     # 16 phases * 14 rows
        # Banks 43-59 are reserved for selective half-row variants.
        if (used_banks + cost <= 43 and
                variant_tiles + variant_cost <= 17 * 256 and
                len(slots) < 16):
            slots.append({"name": t, "max_class": mc})
            used_banks += cost
            variant_tiles += variant_cost
    print(f"textures: {len(slots)} slots, ~{used_banks} banks "
          f"({', '.join(s['name'] + ':' + str(s['max_class']) for s in slots)})")
    slot_of = {s["name"]: i for i, s in enumerate(slots)}

    # unkept textures substitute a kept one with SUFFICIENT class coverage
    # (a too-short substitute would make the engine request pruned slices),
    # preferring the longest shared name prefix (BROWNGRN -> BROWN144,
    # TEKWALL1 -> TEKWALL4, COMPTALL -> COMPUTE2 ...)
    def _cp(a, b):
        n = 0
        while n < min(len(a), len(b)) and a[n] == b[n]:
            n += 1
        return n

    subst_of = {}
    for t in texcount:
        if t in slot_of:
            continue
        req = max_class(texh[t])
        cands = [(i, s) for i, s in enumerate(slots)
                 if s["max_class"] >= req]
        if not cands:
            top = max(range(len(slots)), key=lambda i: slots[i]["max_class"])
            cands = [(top, slots[top])]
        i, s = max(cands, key=lambda e: _cp(t, e[1]["name"]))
        subst_of[t] = i
        print(f"  subst {t} -> {s['name']}")

    def slot(name):
        if name in slot_of:
            return slot_of[name]
        return subst_of.get(name, 0)

    # Per-sector usage counts only wall parts that actually exist and weights
    # them by projected source area.  Palette sets include a two-portal
    # neighborhood: enough to represent walls seen through nearby openings
    # without flattening the whole map to one global pair of hues.
    local_sec_tex = [Counter() for _ in range(len(kept))]
    for i in kept_ss:
        for s in ss_segs[i]:
            back_kept = s["back"] is not None and s["back"] in kept
            fs = sec_renum[s["front"]]
            ff, fc, _ = m["sectors"][s["front"]]
            if back_kept:
                bf, bc, _ = m["sectors"][s["back"]]
                if fc > bc and s["tex"] and s["tex"] != "-":
                    local_sec_tex[fs][slot(s["tex"])] += s["ulen"] * (fc - bc)
                if bf > ff and s["texl"] and s["texl"] != "-":
                    local_sec_tex[fs][slot(s["texl"])] += s["ulen"] * (bf - ff)
            elif s["tex"] and s["tex"] != "-":
                local_sec_tex[fs][slot(s["tex"])] += s["ulen"] * (fc - ff)

    kept_sorted = sorted(kept)
    nall = len(m["sectors"])
    rj = m["reject"]

    def reject_old(i, j):
        bit = i * nall + j
        return bit >> 3 < len(rj) and bool(rj[bit >> 3] & (1 << (bit & 7)))

    sec_tex = []
    for cam_old in kept_sorted:
        sources = {cam_old}
        frontier = {cam_old}
        for _ in range(2):
            frontier = {n for s in frontier for n in adj.get(s, ())
                        if n in kept and n not in sources}
            sources.update(frontier)
        usage = Counter()
        for src_old in sources:
            usage.update(local_sec_tex[sec_renum[src_old]])
        sec_tex.append(usage)

    segs = []
    subsectors = []
    for i in kept_ss:
        first = len(segs)
        for s in ss_segs[i]:
            back = s["back"]
            if back is not None and back not in kept:
                back = None                      # solidify the cut boundary
            ff, fc, _ = m["sectors"][s["front"]]

            def vphase(name, kind):
                si = slot(name)
                actual = slots[si]["name"]
                th = texdefs[actual][1]
                bf, bc = (0, 0) if back is None else m["sectors"][back][:2]
                return vertical_phase(kind, ff, fc, bf, bc, th,
                                      s["rowoff"], s["flags"])

            kind = "solid" if back is None else "upper"
            vp = vphase(s["tex"], kind)
            vpl = 0 if back is None else vphase(s["texl"], "lower")
            segs.append((vid(s["p1"]), vid(s["p2"]), s["ulen"], s["u0"],
                         slot(s["tex"]), slot(s["texl"]), sec_renum[s["front"]],
                         None if back is None else sec_renum[back], vp, vpl))
        subsectors.append((first, len(ss_segs[i]), sec_renum[ss_sector[i]]))

    nodes = []
    for (px, py, pdx, pdy, c0, c1, bb) in new_nodes:
        npx, npy = s114(px, py)
        ndx = round(pdx * SCALE * 16)
        ndy = round(pdy * SCALE * 16)
        bx1, by1 = s114(bb[0], bb[1])
        bx2, by2 = s114(bb[2], bb[3])
        def cref(c):
            return (ss_renum[c[0]], True) if c[1] else (c[0], False)
        nodes.append((npx, npy, ndx, ndy, cref(c0), cref(c1),
                      (bx1, by1, bx2, by2)))
    root = root_ref[0]

    sectors = []
    for old in sorted(kept):
        f, c, light = m["sectors"][old]
        fs = max(-120, min(120, round(f * SCALE)))
        cs = max(-120, min(120, round(c * SCALE)))
        lq = max(0, min(3, 3 - (light >> 6)))
        sectors.append((fs, cs, lq))

    ppx, ppy = s114(sx, sy)
    pang = round(sang * 65536 / 360) & 0xFFFF

    world_thing_kind = {2014: 0, 2015: 1, 2019: 2, 2035: 3, 3004: 4}
    things = [[] for _ in subsectors]
    for tx, ty, _angle, thing_type, flags in m["things"]:
        if (flags & 0x10 or not flags & THING_SKILL_FLAG or
                thing_type not in world_thing_kind):
            continue
        old_ss = point_ss(tx, ty)
        if old_ss not in kept_ss_set or ss_sector[old_ss] not in kept:
            continue
        x, y = s114(tx, ty)
        things[ss_renum[old_ss]].append((x, y, world_thing_kind[thing_type]))

    # WAD REJECT lump: bit set = sector j not visible from sector i
    def reject(i_new, j_new):
        i, j = kept_sorted[i_new], kept_sorted[j_new]
        return reject_old(i, j)

    print(f"trim: kept {len(kept)}/{len(m['sectors'])} sectors, "
          f"{len(kept_ss)}/{len(ss_segs)} subsectors; textures: {slots}")
    return (verts, segs, nodes, subsectors, sectors, root,
            (ppx, ppy, pang), EYE_WAD, reject, things), \
        {"slots": slots, "sec_tex": [dict(c) for c in sec_tex]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wad")
    ap.add_argument("--map", default="E1M1")
    ap.add_argument("--texlist", help="output texture slot list (json)")
    ap.add_argument("--full", action="store_true", help="emit the untrimmed map")
    ap.add_argument("-o", "--out", required=True)
    args = ap.parse_args()

    if args.wad:
        emit_args, texinfo = convert_wad(args.wad, args.map, args.full)
        if args.texlist:
            with open(args.texlist, "w") as f:
                json.dump(texinfo, f)
        emit_map(args.out, *emit_args, full=args.full)
    else:
        emit_map(args.out, *build_micro())


if __name__ == "__main__":
    main()
