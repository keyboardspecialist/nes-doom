# Feasibility

## Thesis

The goal is a playable interpretation of Doom that preserves its spatial and
gameplay identity: BSP-authored rooms, arbitrary wall angles, variable sector
heights, portals, texture identity, occlusion, monsters, combat, pickups, and
map interactions. The adaptation concentrates visual reduction in the raster
representation. Geometry, visibility, and world state retain Doom's structure;
screen columns, wall scales, texture phases, lighting, and color use bounded
representations suited to deterministic frame and storage budgets.

MMC5 is the chosen mapper because it combines the four capabilities that
support this model. Extended attributes select a CHR bank and palette for each
background cell, turning a tilemap entry into a compact reference to a large
pre-rendered wall vocabulary. The scanline counter creates stable view, status,
and transfer regions. The hardware multiplier supports projection and transform
arithmetic at scene scale. Banked PRG and CHR spaces hold the map, generated
slices, sprites, audio, and specialized code while fixed banks keep interrupt
and hot paths resident.

Wall appearances are generated as CHR slices. Runtime rendering writes tile
and ExAttr indices into a double-buffered compose surface, then publishes that
surface by column during scheduled blanking windows. This makes publication
cost proportional to the 32 x 20 tile grid and independent of the source
texture detail represented by each tile. The finite slice atlas is controlled
through height classes, isotropic texture widths, phase quantization,
height-class pruning, and bank-budgeted texture selection.

The renderer follows Doom's visibility model because that architecture is
central to the project: BSP traversal, front-to-back seg processing, solid
column clips, and portal occlusion define how the world becomes a visible
scene. Angle gates and silhouette-corner box tests preserve that hierarchy in
compact table-driven form. Reciprocal depth, interpolated wall heights, and
perspective-correct texture anchors adapt the projected segs to the tile-based
output model.

Visual continuity receives dedicated representations inside the same tile
budget. Mip-filtered slices stabilize distant textures. Sub-row anchoring,
fractional column coverage, and sloped silhouette tiles preserve thin and
oblique geometry. Per-slice hue selection, per-sector palette sets, four-level
luminance quantization, and surface-anchored light dissolves preserve material
and depth separation. Sprite pages carry actors and weapon animation while the
background renderer handles world geometry.

The resulting design sustains a practical 3-15 fps range across E1M1, reaches
30 fps in enclosed views, and keeps the full map, gameplay state, presentation,
and generated assets inside the measured budgets.

### Design Rationale

| Decision | Purpose |
|---|---|
| MMC5 extended attributes | Per-cell CHR bank and palette selection across a large wall atlas |
| Pre-rendered wall slices | Bounded runtime work expressed as tile and attribute writes |
| BSP front-to-back traversal | Early visibility ordering and solid-column closure |
| Angle and bbox gates | Geometry rejection before transform and projection work |
| Double-buffered compose surfaces | Stable publication independent of render-pass duration |
| IRQ and NMI transfer schedule | Predictable column bandwidth across each video frame |
| Height and texture-phase quantization | Finite CHR vocabulary for continuous world geometry |
| Isotropic class mips | Stable texture scale and filtering across depth |
| Eight-column perspective anchors | Perspective texture compression with bounded division cost |
| Sloped boundary tiles | Pixel-scale wall silhouettes within an 8-pixel column renderer |
| Per-sector palette sets | Room-specific color identity through palette data |
| Four luminance bins | Tonal depth from every background palette entry |
| Surface-anchored dissolve | Stable half-step distance lighting during camera movement |
| Banked map and code segments | Full-map capacity with resident interrupt paths |

## Status

| Area | Current state |
|---|---|
| Playable content | Complete medium-skill E1M1 layout and implemented world interactions |
| Render rate | 3-15 fps practical range; enclosed views reach 30 fps |
| Geometry | BSP sectors, portals, variable floors and ceilings, arbitrary wall angles |
| Rendering | Textured walls, per-column occlusion, sprites, distance lighting, sector palettes |
| Gameplay | Collision, weapons, monsters, pickups, barrels, doors, lift, exit |
| Presentation | Title screen, status bar, animated face, music, prioritized sound effects |
| Verification | 25 Python tests and Mesen2 milestones M1-M15 |

## Content Profile

| Resource | Full E1M1 |
|---|---:|
| Vertices | 533 |
| Segs | 816 |
| Subsectors | 237 |
| BSP nodes | 236 |
| Sectors | 85 |
| Runtime things | 64 |
| Active monsters | 6 |
| Doors | 4 |
| Lifts | 1 |
| Exits | 1 |
| Wall texture slots | 16 |

| Trimmed geometry | Count |
|---|---:|
| Sectors | 26 |
| Subsectors | 77 |
| Segs | 255 |
| BSP nodes | 76 |

## Rendering Model

### Output

| Property | Value |
|---|---|
| Viewport | 256 x 160 pixels |
| Tile grid | 32 x 20 cells |
| Compose format | One nametable byte and one ExAttr byte per cell |
| Compose buffers | Two 1,280-byte WRAM buffers |
| Wall source | Build-time CHR slice atlas |
| Runtime publication | Column transfers during the letterbox and vblank windows |

### Quantization

| Parameter | Representation |
|---|---|
| Column width | 8 pixels |
| Wall heights | 1-10, 12, 14, 16, and 20 tile classes |
| Near-wall scale | Vertical pixel doubling above 20 rows |
| Texture width | 64, 32, 16, 8, or 4 texels per column by height class |
| Texture phase count | 64 divided by class texel width |
| Horizontal perspective | Exact anchors every eight columns; exact tails |
| Vertical placement | Sub-row texture anchoring |
| Wall boundaries | 128 sloped silhouette tiles with 1-pixel endpoint precision |
| Wall color | Four luminance bins, including the black backdrop |
| Palette model | Two hue ramps by two light levels |
| Distance transition | Surface-anchored half-step dissolve |
| Floor lighting | Sector light plus row-based distance thresholds |

### Visibility And Projection

| Stage | Implementation |
|---|---|
| Traversal | Front-to-back BSP |
| Seg gate | BAM angle span, frustum clip, and column-occlusion scan |
| Node gate | `R_CheckBBox`-style silhouette-corner test |
| Backface handling | Angle classification with exact-path fallback |
| Projection | Endpoint reciprocal depth and linear screen-space interpolation |
| Wall heights | Endpoint height terms interpolated per column |
| Texture coordinates | Piecewise perspective-correct `u/z` interpolation |
| Portal handling | Upper and lower wall parts with per-column clips |
| Thin geometry | Fractional column coverage for sub-column spans |
| Distant geometry | Sub-row edge coverage for zero-row spans |
| Arithmetic | MMC5 8x8 multiplier, reciprocal tables, compact log/atan tables |
| Vertex reuse | 256-entry generation cache plus tagged high-index side cache |

### Surfaces And Sprites

| Element | Representation |
|---|---|
| Walls | Mip-filtered texture slices |
| Floors | Sector palette color with row lighting |
| Ceilings | Sector backdrop color |
| World sprites | Six 1 KiB pattern pages |
| Weapon sprites | Two 1 KiB pattern pages selected per frame |
| Sprite density | Eight sprites per scanline |
| World atlas | 188 patterns and 227 cells |
| Weapon frames | Four generated frames |

## Frame Schedule

| Phase | Work |
|---|---|
| Lines 0-159 | 3D view |
| Line 160 | HUD CHR window and palette load |
| Lines 160-199 | Status bar |
| Line 199 | Rendering blank and ExRAM CPU-write mode |
| Lines 199-240 | Ten viewport-column transfers |
| NMI | OAM DMA, two E1M1 viewport columns, gameplay palette restore, display state restore |

| Transfer metric | Value |
|---|---:|
| Column payload | 20 nametable bytes and 20 ExRAM bytes |
| Measured column cost | Approximately 410 CPU cycles |
| E1M1 normal quota | 12 columns per video frame |
| Synthetic normal quota | 13 columns per video frame |
| E1M1 publication floor | Approximately 2.7 video frames |
| Synthetic publication floor | 2.49 video frames |
| HUD update quota | Face or numeric upload uses the NMI column allocation for that frame |

## Lighting And Palettes

| Scope | Behavior |
|---|---|
| Gameplay | Four generated background palettes |
| Status bar | Four dedicated background palettes |
| Sector selection | Camera sector chooses the gameplay palette set |
| Texture selection | Each slice carries its warm/cool ramp bit |
| Light selection | ExAttr carries the bright/dark bit |
| Ramp stability | Ramp regions align to 16-texel texture blocks |
| Backdrop | `$0F` black |
| Dynamic capacity | Per-frame gameplay palette load supports flashes and light effects |

## Status Bar

| Element | Implementation |
|---|---|
| Base art and digits | 125 deduplicated tiles in physical CHR bank 125 |
| Face atlas | 13 fixed 4 x 4 frames in physical CHR bank 127 |
| Face states | Five health tiers, five pain tiers, two healthy alternates, death |
| Pain duration | 60 video frames |
| Healthy idle period | 30 video frames |
| Face palette | Fixed flesh palette across all 16 cells |
| Animation transfer | Four 4-byte nametable runs |
| Counters | Runtime ammo, health, and armor updates |

## Gameplay

### Player And World

| System | Current behavior |
|---|---|
| Player collision | 6.4375-unit circle against BSP leaf geometry |
| Portal clearance | Opening height, step height, line flags, and dynamic door state |
| Movement query | Current and candidate BSP leaves |
| Eye height | Fixed offset from the mutable sector floor |
| Pickups | 16-unit radial scan over active things |
| Doors | Use activation, opening, wait, closing, collision, and sound states |
| Lift | Side-transition activation, lowering, wait, raising, and floor collision |
| Exit | Use activation, report sound, and return to title |

### Combat And Actors

| System | Current behavior |
|---|---|
| Weapons | Pistol and shotgun-ammunition behavior |
| Targets | Zombiemen, imp-kind actors, and barrels |
| Monster movement | Direct collision-tested pursuit in one-unit axis steps |
| Monster attacks | Range, timing, static-wall LOS, and dynamic-door LOS |
| LOS sampling | Six-unit collision radius across bounded trace steps |
| Damage state | Health, armor type, armor absorption, pain report, death |
| Persistence | Thing health, deaths, explosions, pickups, and active flags |
| Actor capacity | 64 things and 8 monster state slots |

## Audio

| Resource | Allocation |
|---|---|
| Guitar tracks | Two base pulse and two MMC5 pulse channels |
| Bass | Triangle channel |
| Percussion | Long-LFSR noise |
| Gameplay reports | Prioritized noise events |
| Music loop | 96 seconds |
| Music data | 7,985 bytes in PRG08 |
| Runtime command rate | Up to six channel updates per frame |

## Performance

| Scenario | Measured render pass |
|---|---:|
| Enclosed trimmed-map view | 2-3 frames |
| Portal room and corridor micro-map | 4-7 frames |
| Trimmed E1M1 start view | 19 frames |
| Full E1M1 southern view with six monsters | 14 frames |
| Full E1M1 start-view regression bound | 30 frames |

| Throughput sample | Result |
|---|---:|
| Synthetic publication | 100 flips in 600 frames |
| Trimmed E1M1 publication | 73 flips in 700 frames |

## Operating Bounds

| Resource | Bound |
|---|---|
| Wall textures | 16 map texture IDs |
| Gameplay texture window | 64 physical 4 KiB banks |
| BSP indices | Byte-sized nodes and subsectors |
| Seg endpoints | 16-bit vertex indices in the full build |
| Things | 64 runtime entries |
| Monsters | 8 runtime state entries; full E1M1 activates 6 |
| Sprite scanline load | 8 sprites |
| Near clip | 16 world units |
| Texture span | 256-texel modular `u` range per seg |
| Physical implementation | Custom board layout with 1 MiB CHR capacity |
| Timing qualification | Scanline-counter blanking and ExRAM write-mode checks on final hardware |
| Resource placement | `doc/memory-budgets.md` |

## Content Pipeline

| Tool | Output |
|---|---|
| `tools/wadlib.py` | Lump access, texture composition, palette data, and REJECT data |
| `tools/mapconv.py` | BSP geometry, sectors, things, specials, texture slots, and bank splits |
| `tools/tilegen.py` | Wall slices, silhouettes, sprites, HUD, title, palettes, and LUTs |
| `tools/musicgen.py` | 60 Hz channel command stream |
| `tools/tablegen.py` | Math and projection lookup tables |

## Verification

| Coverage | Tests |
|---|---|
| Boot, IRQ, ExAttr, transfer timing | M1-M3 |
| Wall and BSP rendering | M4-M5 |
| Weapon sprites, HUD counters, combat | M6-M8 |
| Enemies, title, music | M9-M11 |
| Collision, doors, animated face | M12-M14 |
| Full-map pickups, LOS, lift, exit | M15 |
| Content generation | 25 Python tests |
| Full-map structure and performance | `test/e1m1_full.lua` |

### Commands

| Command | Scope |
|---|---|
| `make` | Synthetic and M2 builds |
| `make e1m1` | Trimmed E1M1 build |
| `make e1m1-full` | Full E1M1 build |
| `make test` | Complete automated suite |

## Automation

| Trigger | Action |
|---|---|
| `master` push | Build, test, and upload the full ROM artifact |
| Pull request | Build and test |
| Manual dispatch | Build, test, and upload the artifact |
| `v*` tag | Build, test, and publish the ROM release asset |
