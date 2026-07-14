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
| Wall screen height | 13 classes {1–8,10,12,14,16,20} tiles; class = smallest ≥ span; spans > 20 pixel-double vertically |
| Texture u | 8-texel phases (4-texel, 16 phases for zoom classes 12-20), du/dx fixed within a slice |
| Vertical | wall tops snap to tile rows (horizon at row 10, eye fixed 48 units) |
| Light | 4 levels = ExRAM palette bits (sector light + distance, clamped) |

Measured tile cost: **1360 tiles per texture** since the 2x-zoom classes
(866 before them), 6 x 4KB banks each. At 6 banks/texture, **10 textures +
flats fill one 256KB $5130 window**; 1MB CHR holds 4 per-level texture
sets. Light costs zero tiles.

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
- Texture u is now perspective-corrected in 8-column chunks (see below);
  residual affine drift within a chunk is under the 8-texel phase quantum.
  Spans over 20 rows render pixel-doubled vertically (vshift) instead of
  cropping, so near walls no longer smear their last texel row.
- One shared 3-color ramp across wall textures (2bpp tiles + 4-palette ramp);
  flats are solid colors (no span texturing); no sky yet (trivial: strips).
- Fixed eye height; camera stays walkable-area-clamped.
- The micro-map is hand-authored; a real WAD subset needs mapconv.py to
  parse/rescale WAD lumps and split segs on partition lines (mechanical, but
  unwritten). Doom-scale coordinates must rescale into s11.4 (±2047 units).
- Full (untrimmed) E1M1 is deferred but scoped: 467 verts / ~816 split segs /
  237 subsectors / 236 nodes / 85 sectors / 32 textures. Needs a second map
  bank at $A000 (segs alone = 8160B), ss_*/sec_*/reject copied to PRG-RAM at
  boot ($6A00-$7FFF free), a seg-record zp copy in do_seg across the bank
  switch, frequency-sorted vertices so the 256-entry angle cache covers the
  hottest (16-bit fallback for the rest), and nearest-color texture
  substitution instead of mapconv's current "everything else -> slot 0".
  Node/subsector byte indices still fit.

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

**Measured on E1M1** (Mesen2, before angle clipping): enclosed views 6
frames/pass (10 fps); mid views 20-22; the worst case — the start-point
panorama down the whole hangar — 32 frames (~1.9 fps). Profiling showed
~2,200 hardware multiplies per pass, dominated by segs inside the frustum
but occluded by nearer walls (occlusion tested only after
transform+projection) and by the 6-multiply half-plane bbox cull.

## Angle-based clipping (R_AddLine / R_CheckBBox port, third session)

Doom's trick, now implemented: reject backfacing / off-frustum / occluded
geometry using only BAM angles, before any transform multiplies.

- **Division-free atan2** (`atan2_hi`): fold into the first octant, ratio =
  `min * recipf[(max+8)>>4] >> 15` on the MMC5 multiplier, 256-entry
  `atan_tbl` (BAM high-byte units, generated by tablegen). Accuracy ±2
  units (±2.8 deg); C-flag "too close" fallback when both deltas < 16
  world units (recipf clamps there).
- **Per-vertex angle cache**: segs share vertices, so `vert_angle`
  memoizes angles in a 256-entry table + done/near bitmaps, cleared per
  pass (maps are capped at 256 vertices — mapconv asserts). A pass computes
  ~120 atans for ~340 lookups.
- **Seg angle gate in do_seg**: span = a1-a2 classifies winding with ±4
  slack — 133..251 certain backface (rejected, zero multiplies), 124..132
  is the wall-hugging wrap zone (true span ~180 deg, clip arithmetic
  invalid -> exact path), small spans normalize order and run Doom's
  R_AddLine tspan frustum clips, then an occlusion scan of the column
  range (angle -> column via `angcol_tbl`, ±2 column slack) against the
  per-column clip state. Certain-front spans (5..123) also skip the
  2-multiply exact backface test.
- **bbox_cull is now R_CheckBBox**: camera-region table (9 cases) picks
  the box's two silhouette corners (expanded 1 page outward — converter
  bboxes are floor-truncated), `atan2_pg` computes their angles from PAGE
  deltas via `recip_col` (two raw 8x8 MMC5 products, no mul16 calls), then
  the same frustum + occlusion-scan logic. This culls whole subtrees
  behind already-solid columns — the old dot-product cull could only
  reject off-frustum boxes. Keeps (never culls) when the camera is inside
  the box, within 4 pages, or the box subtends >= 124 units (~175 deg).

**Measured after** (same E1M1 vantages): start panorama 32 -> 20
frames/pass (3.0 fps), enclosed 6 -> 2 (30 fps), mid views 14-20 -> 5-13;
M5 micro-map worst 7 -> 6. Start-view multiplies 2,188 -> 1,014; do_seg
calls 173 -> 111 (occluded subtrees no longer descend). Verified
pixel-identical against the pre-clipping renderer at the start view plus a
7-vantage interior sweep (screen-hash A/B in Mesen); the only diverging
vantage is the deliberately degenerate e1m1.lua "near-wall" teleport,
which clamps the camera to the world-min boundary looking out of the
trimmed map — a void view where the drawn set legitimately depends on
cull order (that test only asserts speed).

Precision hazard worth recording: an early version classified spans 0..4
as "ambiguous winding" and skipped the gate for them — but most segs in a
real map subtend tiny angles from any distant vantage, so the gate never
fired. Slack bands must wrap around the *certain* classifications
(backface, wall-hugging), not around "front".

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

**Palette-aware quantization (third session — the previously-noted
"endgame", now in).** The ramp is chosen per SLICE, not per texture: the
ramp bit rides bit 7 of each `slice_bank` LUT byte (banks stay < 64, bits
6-7 free), so palette selection is per-8px-strip at zero runtime cost and
the per-texture `tex_ramp` plumbing is gone. tilegen scores each strip's
chroma-weighted bin means against both ramps — luminance-SCALED before
comparing, the same trick as ramp derivation, because raw nearest-RGB
matching collapses dark Doom art onto whichever ramp is darkest (tried it:
the whole map went gray). Pixels still bin by the texture's global
luminance thresholds (keeps relative contrast), with a 2x2 ordered dither
in a ±30%-of-bin band around each threshold. Result: STARTAN walls carry
warm tan strips and cool gray computer-panel strips side by side.

Refinements after first playtesting (same session):

- **Ramp coherence.** Independent per-strip argmin made near-tie strips
  flip ramps randomly — walls striped. Now the texture's majority ramp
  wins unless a strip prefers the other by a wide margin (< 0.55x error).
  Ramp stays per (texture, phase) across all height classes, so a wall
  section never changes ramp on approach.
- **Box-filtered sampling.** Both decimations were nearest-neighbor (WAD
  compose -> 64x64 point sample; 64 rows -> class height by row-dropping),
  which aliased thin details away and turned distant classes into noise.
  Both steps now area-average in RGB (`box_resample`), and quantization +
  dither run at final class resolution (`quantize_rows`), so the dither
  pattern can't moire through a rescale. The --game synthetic textures
  keep the old index-map path.
- **Row-lit floors.** First attempt gave floors the wall column's light
  bit (`emit_lt`) — floor shading banded vertically wherever wall segs
  changed depth, which reads as nonsense. Floor depth is a function of
  screen ROW for a fixed eye height (z = 656/(row-10)), so the light now
  comes from a 4-entry per-sector threshold table (`fl_thr_tbl`, sector
  light -> first bright row; ~8 cycles/row): a smooth horizontal fade to
  dark at the horizon, constant per sector. Sectors whose floor sits far
  below the eye shift the true bands; the fixed table ignores that.

## Close-range magnification (fourth session)

Slices bake horizontal texture at a fixed 1 texel/px, but vertical scale
grows with the height class — at class 16 a wall is 0.5 texel/px
vertically. Up close the axes disagree: u advances < 8 texels per column,
so phases repeat and the wall reads as the same 8-texel strip stamped at
column frequency ("texture repeats faster as you approach"). Two more
close-range bugs stacked on top: row offsets clamped at ±30 rows, so
nearer than that the texture's vertical anchor saturated and the texture
visibly slid; and spans > 20 rows clamp to class 20 with the row offset
pinned to the last slice row — the bottom of near walls smeared one texel
row. Fixes:

- **2x-zoom slice sets** for classes 12/14/16/20: 4 texels per column
  stretched to 8 px, 16 phases (4-texel granularity), matching those
  classes' vertical magnification. `set_slice` picks phase (u>>10)&15 via
  a per-class LUT base offset table; zoomed slices inherit the parent
  8-texel strip's palette ramp. Cost: 1360 tiles = 6 CHR banks per texture
  (ExAttr bank field is 6 bits = 64 banks per frame window), so texture
  slots drop 15 -> 10 (mapconv MAX_TEX; trim-local top-10 covers ~90% of
  visible surfaces). FLAT_BANK stays 60 for E1M1; the --game build moves
  to FLAT_BANK 12.
- **Vertical pixel-doubling for spans > 20 rows** (`vshift`): halve the
  span until a class fits and shift the emit row offset right by the same
  amount — the texture covers the whole wall in blocky 2x/4x rows instead
  of smearing its last row, and pairs with the horizontal zoom so both
  axes magnify together.
- **clamp30 -> clamp60** on the per-column row offsets: covers every
  reachable span (near clip at 16 units caps full walls at ~51 rows), so
  the vertical anchor no longer saturates and slides.
- **Ramp fixes**: isolated-deviant smoothing (a strip flanked by two
  majority-ramp strips reverts) on top of the majority-margin rule, and
  `ramp_base` now picks ONE hue column for a whole ramp (summed over the
  three bins) — per-row independent matching had produced incoherent
  ramps like yellow/gray/black. E1M1 derives tan {37,27,17} + gray
  {20,10,00}.

- **Dissolve lighting.** With coherent textures, the hard 2-level
  distance-light step read as a vertical band across long walls. Per-seg
  light does not fix it (mapconv splits long walls at ~255 texels, so the
  step lands mid-wall anyway — tried and reverted). Instead `light2_tbl`
  doubles the distance-light resolution (7 values); dark at >= 6, and the
  half-band at exactly 5 dissolves by column parity. The floor fade
  boundary row dithers the same way. One light bit is the hard limit
  here; the remaining lever is trading the second hue ramp for 4 light
  levels (4 palettes = 1 ramp x 4 lights) if diminishing ever matters
  more than hue variety.

Measured: pass-frame envelopes essentially unchanged (M5 worst 7, E1M1
start 20, near-wall 2). Close walls now show the texture at the correct
scale with no repetition, sliding, or smear; light transitions read as
dissolves instead of bands.

**Sub-row walls no longer vanish (pop-in fix).** A wall whose screen span
rounds to zero rows used to emit nothing — distant steps and lintels
popped into existence on approach. But the boundary interpolators already
carry sub-tile fractions: a zero-row wall is exactly ek_top pixels above
the row line plus ek_bot pixels below it, which is what the shared edge
tiles render. The fix is three tiny emit-path branches that arm
`emit_edges` (ew_top/ew_bot) for zero-span solid walls, zero-span upper
portal walls, and zero-span lower walls (stair edges — the common case),
with exbyte carrying the light bits. Distant geometry now fades in as a
1-7px line instead of appearing from nothing; same pass-frame cost.

**Perspective-correct texture u (chunked resync).** u/z is linear in
screen x, and the per-column rzh (∝1/z) interpolant already exists — so
do_seg now also carries uoz = u·rzh/256 (16-bit, two extra multiplies per
seg for the endpoints + one for the step). Every 8th drawn column,
`resync_u` re-anchors the affine u accumulator with the exact
u = (uoz << 16)/rzh — a 16-step restoring division, ~420 cycles. The
quotient provably fits 16 bits: u < 256 texels ⇒ uoz < rzh at both
endpoints, and both interpolate linearly, so the invariant holds at every
column. Gated to spans > 8 columns (narrow spans can't drift a visible
amount) and to segs whose u range doesn't wrap 256 texels (u interpolates
mod 256 texels; a wrap makes uoz a sawtooth, not a line — those keep
affine). Measured: zero pass-frame cost on every test vantage; visually,
grazing views of long walls now compress texture detail toward the far
end instead of smearing it evenly (affine's classic swim). The between-
anchor error is bounded by 8 columns of drift, under one 8-texel phase in
practice.

## Profiling harness (notes)

Mesen2's lua `emu.addMemoryCallback(fn, emu.callbackType.exec, addr)`
counts routine entries between two `render_bsp` entries = exactly one
render pass; `emu.getState()["cpu.cycleCount"]` brackets the cycles.
Addresses come from the ld65 `--dbgfile` (grep `sym.*name="mul16u"` etc).
The zp profiling counters ($80-$82) are reset per pass, so lua reads at a
fixed frame catch them mid-pass — only `pass_frames` ($80, written at pass
end) is trustworthy there. The testrunner lua sandbox has no `io`/`os`:
export screens by printing FNV hashes (or hex pixel rows) to stdout.

## Repro

```
make            # builds nesdoom.nes (micro-map PoC) + nesdoom-m2.nes
make e1m1       # builds nesdoom-e1m1.nes from Doom1.WAD (in repo root)
make test       # M1..M5 in Mesen2 headless testrunner
make test-e1m1  # E1M1 structural + performance-envelope test
```

ROMs: 1,179,664 bytes each (16B header + 128KB PRG + 1MB CHR), mapper 5, NES 2.0.
