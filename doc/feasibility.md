# Doom on the NES via MMC5 — Feasibility Study

**Verdict: feasible at ~8–15 fps with real Doom geometry, heavily quantized.**
A proof-of-concept ROM in this repository renders BSP-traversed sectors with
variable floor/ceiling heights, arbitrary wall angles, textured walls, portal
occlusion, and per-sector + distance lighting on emulated stock NES hardware
(MMC5 mapper), verified by an automated Mesen2 test suite (`make test`,
milestones M1–M5). All numbers below are measured from those runs
(NTSC timing, Mesen2 on macOS, 2026-07-13).

No native NES Doom or Wolfenstein port existed before this; the 2019 "Doom on
an unmodified NES" ran a Raspberry Pi inside the cartridge. The closest real
prior art — tokumaru's raycaster (nesdev.org t=5596, 12–15 fps on hardware,
178 pre-rendered tiles, no MMC5) — validated the core strategy this project
scales up.

## The core idea: write tile indices, not pixels

A CHR-RAM framebuffer dies on NTSC vblank bandwidth (2273 CPU cycles/vblank
≈ 160–380 bytes; a modest bitmap frame needs kilobytes — Elite shipped
PAL-only for exactly this reason). Instead:

1. **Every wall appearance is pre-rendered into CHR-ROM at build time.** A
   "slice" = one (texture, height-class, u-phase): an 8-px-wide column of the
   texture rescaled to H tiles, stored contiguously in one 4KB bank.
2. **MMC5 extended-attribute mode ($5104=%01)** gives every background tile
   its own ExRAM byte: bits 0–5 pick a 4KB CHR bank (+2 global bits in $5130
   → 16,384 tiles visible per frame, 4 such windows in 1MB), bits 6–7 pick
   the palette. Runtime "drawing" is 1 nametable byte + 1 ExRAM byte per 8×8
   cell.
3. The engine is Doom's renderer shape — BSP front-to-back, seg projection
   with per-endpoint perspective divide, per-column occlusion clips — but its
   output is tile indices in a PRG-RAM compose buffer, pushed to the PPU by a
   scanline-IRQ-driven pipeline.

### Quantization lattice (what makes the tile set finite)

| Parameter | Quantization |
|---|---|
| Column width | 8 px (32 columns) |
| Wall screen height | 13 classes {1–8,10,12,14,16,20} tiles; class = smallest ≥ span, bottom rows crop |
| Texture u | 8-texel phases (8 per 64-px texture), du/dx fixed within a slice |
| Vertical | wall tops snap to tile rows (horizon at row 10, eye fixed 48 units) |
| Light | 4 levels = ExRAM palette bits (sector light + distance, clamped) |

Measured tile cost: **866 tiles per texture** (1732 for two textures + 4 flat
tiles, packed into 9 × 4KB banks = 36KB). At 4 banks/texture, **16 textures
fill one 256KB $5130 window**; 1MB CHR holds 4 per-level texture sets.
Light costs zero tiles.

## Frame pipeline (measured)

Screen: 3D view 32×20 tiles (256×160), status bar rows 20–24 (lines 160–199),
letterbox lines 200–240. Two MMC5 scanline IRQs per frame (compare $5203,
single-scanline precision measured: IRQ lands on line 160/199 every frame):

- **Line 160**: status-bar split (static tiles; just re-arm for 199).
- **Line 199**: blank rendering → 42-line letterbox window; flip ExRAM to
  mode %10 (CPU-writable while blanked); push 10 columns.
- **NMI (241)**: OAM DMA first, push 3 more columns, restore ExAttr mode +
  scroll + rendering, re-arm IRQ (mandatory: in-frame detection stops while
  blanked, so NMI is the only guaranteed wake-up).

Measured push cost: **~410 cycles per column** (20 NT bytes via $2007
increment-32 + 20 ExRAM absolute stores, fully unrolled per column, two 8KB
code banks of generated pushers dispatched through a bank-top JMP table).
13 columns/frame → **full 1280-byte frame flip in 2.49 frames** (241 flips in
600, pusher-limited). Letterbox blank timing: scanline 199 with zero jitter
(±1 line reported once the renderer loads the main thread; the seam is black).

## Renderer cost (measured, micro-map: 3 sectors, 25 segs, 5 BSP nodes)

| Vantage | Scene | Render pass |
|---|---|---|
| Room center, portal + walls | solid + portal composite | 6 frames (10 fps) |
| Facing pillar (occlusion) | near solid wall dominates | 4 frames (15 fps) |
| Down corridor into far room | 2 portals, floor step, far wall | 5 frames (12 fps) |
| Deep room looking back | portal lintel + corridor | 7 frames (8.6 fps) |

The flat-room renderer (M4, no BSP) measured 3 frames/pass; the render pass,
not push bandwidth, is now the bottleneck. Per-column work is Doom's shape:
1/z (rzh = 524288/z, from a 1KB reciprocal table) interpolates linearly in
screen x, and per-seg height terms (h·rzh≫15) interpolate the same way — so
each column costs only adds, table lookups, and the emit loop; all multiplies
(camera rotate, projection, steps: ~20 per seg) run on the MMC5 multiplier
($5205/$5206, instant 8×8→16; a signed 16×16 costs ~130–160 cycles vs ~500
in software).

## MMC5 feature scorecard

| Feature | Role | Verified |
|---|---|---|
| ExAttr per-tile bank+palette | the entire rendering model | M2: bank bits, palette bits, both write paths |
| $5130 upper bits | per-level 256KB texture windows | M2: displayed tiles change with $5130 |
| ExRAM write timing | mode %10 during blank / %01 during render | M2: both land identically (emulator) |
| Scanline IRQ | status split + letterbox bandwidth | M1/M3: exact line, every frame |
| Multiplier | all projection math | M4/M5 renders correct geometry |
| PRG-RAM ($5113) | double compose buffers (2×1280B) + scratch | M3+ |
| 1MB PRG/CHR | tables + slices (36KB CHR used so far) | build |

**Hardware caveats.** (1) In Mesen, blanking mid-frame freezes the MMC5
scanline counter at the compare value and the pending flag re-asserts after
every ack — an IRQ storm. Disabling the IRQ in the last handler of the frame
(NMI re-enables) fixes it and is correct practice regardless; hardware
behavior should be confirmed on a cart. (2) The mode-%10 ExRAM write
workaround is documented on nesdev but flagged "test on hardware." (3) No
commercial MMC5 board shipped 1MB CHR-ROM (ETROM/EWROM top out at 128KB);
the ROM is NES 2.0-legal but real hardware means a custom board.

## Honest limitations at this stage

- **Sprites are the weak point** (not yet in the PoC): OAM 8×16 with MMC5's
  separate sprite banks and prescaled frames works, but 8 sprites/scanline
  = 64px of enemy per line; flicker-cycling and low monster caps required.
- Affine texture u (swim at oblique angles); slice-class crop stretches the
  bottom texel row when a wall exceeds the view; spans > 255 columns use a
  clamped interpolation step (distortion only when very close).
- One shared 3-color ramp across wall textures (2bpp tiles + 4-palette ramp);
  flats are solid colors (no span texturing); no sky yet (trivial: strips).
- Fixed eye height; camera stays walkable-area-clamped.
- The micro-map is hand-authored; a real WAD subset needs mapconv.py to
  parse/rescale WAD lumps and split segs on partition lines (mechanical, but
  unwritten). Doom-scale coordinates must rescale into s11.4 (±2047 units).

## Scaling estimates to "real" content

A stripped E1M1-class scene means ~10–20 visible segs and deeper BSP walks —
the measured per-seg overhead (~20 multiplies ≈ 3k cycles) and per-column
emit (~400–600 cycles) put a 30-seg view around 5–7 frames/pass: the PoC's
measured envelope, i.e. **~8–12 fps holds if visible-seg counts stay Doom-like**.
CHR budget (16 textures/level window) and PRG (128KB used: 4.4KB tables/map,
2.7KB code, 16.3KB pushers — 1MB available) leave enormous headroom for
sprites, more height classes, more textures, and a status-bar font.

## Real WAD content: E1M1 (added 2026-07-13, second session)

A full WAD pipeline now builds `nesdoom-e1m1.nes` from shareware `Doom1.WAD`:

- **tools/wadlib.py** parses the WAD (lumps, TEXTURE1/PNAMES patch
  composition, PLAYPAL, REJECT).
- **tools/mapconv.py --wad** converts E1M1's own BSP: rescale x0.4 (s11.4
  range), split segs > 255 texels, trim by sector-BFS from the player start
  to an 8KB bank budget (kept 26/85 sectors, 77/237 subsectors, 255 segs,
  76 nodes), splice the BSP over kept leaves, solidify cut-boundary portals,
  select the top-15 wall textures, carry seg u-offsets + upper/lower
  textures, translate the REJECT matrix.
- **tools/tilegen.py --wad** composes each texture from patches, quantizes
  to 3 luminance bins, and prescales 12,964 slice tiles (244KB CHR).

Engine growth this required: signed sector heights with a per-frame eye
(floor of the camera's BSP-located sector + 41u), vertex-table seg records
with texture u-offsets and separate lower textures, 16-byte BSP nodes with
subtree bboxes, and a three-plane (behind/left/right frustum) bbox cull run
per node and — tighter — per subsector, plus early backface rejection from
raw deltas (2 multiplies) and z-first transforms.

**Measured on E1M1** (Mesen2): enclosed views 6 frames/pass (10 fps);
mid views 20-22; the worst case — the start-point panorama down the whole
hangar — 32 frames (~1.9 fps). Profiling shows the cost is ~1,700 hardware
multiplies per pass, dominated by segs that are inside the frustum but
occluded by nearer walls: frustum culls cannot remove them, and our
occlusion test runs after transform+projection. **The known fix is Doom's
own next trick — angle-based solidsegs clipping via division-free atan
tables (R_AddLine), rejecting occluded segs before any transform** — the
single biggest remaining optimization, not attempted here.

Also fixed en route and worth recording: the MMC5 multiplier retains each
factor register, so a 16x16 multiply can rewrite only one register per
partial product (order al*bl, al*bh, ah*bh, ah*bl) — ~20 cycles saved per
multiply, verified by geometry correctness in Mesen.

**Data-driven palettes.** tilegen now derives the 4-light BG palette ramp
from the actual texture colors: pixels are binned bright/mid/dark per
texture; bin RGB means are accumulated chroma-weighted (so colorful pixels
outvote gray mortar); each bin is pinned to a fixed NES luminance row
(3/2/1) and only the hue column is matched, against the bin color scaled to
the candidate's luminance. Raw nearest-color matching fails — Doom art is
dark, everything lands in row 0 and the light ramp collapses to black.
E1M1 derives {$37,$27,$18} (tan / orange-brown / olive), stepped one row
darker per light level. The ROM loads BG palettes from the generated LUTs;
only sprite palettes remain hardcoded.

**Two-ramp split.** The 4 BG palettes are now 2 hue ramps x 2 light levels:
tilegen clusters textures warm/cool by chroma-weighted warmth (E1M1: tan
ramp for STARTAN/BROWN, gray ramp for TEK/COMP/DOOR), the per-texture ramp
bit rides ExAttr palette bit 7 and light bit 6, carried per wall part
(upper/lower can differ). Gray ramps use NES rows 2/1/0 because $30 and $20
are the same white. Light = dark when sector light + distance >= 3.

**Pixel-precise silhouettes (edge tiles).** Wall top/bottom boundaries no
longer snap to 8px tile rows. The backdrop color IS the ceiling color
(ceilings are blank tiles), so 14 shared edge tiles (k=1..7 wall pixels
against ceiling color above / floor color below) can render the boundary
under any wall palette. The per-seg height interpolators already carry
sub-tile precision (acc bits 4-6); emit overwrites the flat row adjacent to
each true (unclipped) wall boundary with edge[k]. Verified: an oblique wall's
top edge steps k = 2,3,4,4,5,5,6,6 across columns — 1px silhouette steps for
16 shared tiles and ~50 cycles/column. Edge rows are flat-shaded (the
"cheap tier"); textured edge tiles (+128/texture, still 4 banks) remain the
upgrade path. Portal inner boundaries (lintels/sills) stay tile-snapped by
design — an edge tile there would paint over the portal's far content.

**Future direction (noted):** ExAttr makes palette selection per-tile across
16,384 tiles — the ramps above are a global simplification. The endgame is
palette-AWARE quantization: tilegen scoring each slice (even each tile)
against all 4 palettes and dithering into the best one, rather than binding
whole textures to a ramp. Same hardware, purely a converter upgrade.

## Repro

```
make            # builds nesdoom.nes (micro-map PoC) + nesdoom-m2.nes
make e1m1       # builds nesdoom-e1m1.nes from Doom1.WAD (in repo root)
make test       # M1..M5 in Mesen2 headless testrunner
make test-e1m1  # E1M1 structural + performance-envelope test
```

ROMs: 1,179,664 bytes each (16B header + 128KB PRG + 1MB CHR), mapper 5, NES 2.0.
