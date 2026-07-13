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

## Repro

```
make            # builds nesdoom.nes (PoC) + nesdoom-m2.nes (diagnostics)
make test       # M1..M5 in Mesen2 headless testrunner
```

ROM: 1,179,664 bytes (16B header + 128KB PRG + 1MB CHR), mapper 5, NES 2.0.
