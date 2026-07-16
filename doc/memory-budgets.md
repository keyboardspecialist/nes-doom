# Memory Budgets

## Summary

| Resource | Capacity | Allocated | Available |
|---|---:|---:|---:|
| PRG-ROM | 131,072 bytes | 72,561 bytes | 58,511 bytes |
| CHR-ROM | 1,048,576 bytes | 536,576-byte generated extent | 512,000-byte tail |
| Active WRAM bank | 8,192 bytes | Approximately 6,460 bytes | Approximately 1,732 bytes |
| Volatile PRG-RAM | 32,768 bytes | One active 8 KiB bank | Three reserve 8 KiB banks |

## PRG-ROM

### Full E1M1 Layout

| Bank | Segment | Allocated | Available |
|---:|---|---:|---:|
| 00 | LUTs | 8,123 | 69 |
| 01 | Common map data and LUTs | 6,053 | 2,139 |
| 02 | Column pusher A | 8,128 | 64 |
| 03 | Column pusher B | 8,128 | 64 |
| 04 | Seg bank 0 | 8,184 | 8 |
| 05 | Seg bank 1 | 1,608 | 6,584 |
| 06 | Vertices and nodes | 5,908 | 2,284 |
| 07 | Title code and data | 1,936 | 6,256 |
| 08 | Music | 7,985 | 207 |
| 09 | HUD face upload code | 75 | 8,117 |
| 0A | Reserve | 0 | 8,192 |
| 0B | Reserve | 0 | 8,192 |
| 0C | Reserve | 0 | 8,192 |
| 0D | Door, lift, and exit code | 1,272 | 6,920 |
| 0E | Main code | 7,844 | 348 |
| 0F | Fixed code and vectors | 7,317 | 875 |

| Build | Allocated | Available |
|---|---:|---:|
| Full E1M1 | 72,561 bytes | 58,511 bytes |
| Trimmed E1M1 | Approximately 56.1 KiB | Approximately 75.0 KiB |

### Bank-Local Allocation

| Bank | Available | Allocation policy |
|---:|---:|---|
| 04 | 8 bytes | Preserve seg-bank split boundary |
| 02-03 | 64 bytes each | Preserve generated pusher layout |
| 08 | 207 bytes | Music command data only |
| 0E | 348 bytes | Hot main code |
| 0F | 875 bytes | Interrupt-visible and fixed code |
| 09 | 8,117 bytes | HUD and related cold code |
| 0D | 6,920 bytes | World-special code |
| 0A-0C | 24,576 bytes | New banked systems and data |

## CHR-ROM

### Extent

| Measurement | Size |
|---|---:|
| Generated extent | 536,576 bytes / 524 KiB |
| ROM tail | 512,000 bytes / 500 KiB |
| Total | 1,048,576 bytes / 1 MiB |
| Highest allocated 4 KiB bank | 130 |

### Layout

| 4 KiB banks | Allocation |
|---:|---|
| 0-42 | Wall texture slices |
| 43-59 | Half-row wall variants |
| 60 | Flat, status, and portal helpers |
| 61 | HUD source copy |
| 62 | Wall edge silhouettes |
| 63 | Gameplay expansion |
| 64-67 | World and weapon sprites |
| 68-124 | Reserve |
| 125 | Runtime HUD copy |
| 126 | Reserve |
| 127 | Thirteen 4 x 4 HUD face frames |
| 128-130 | Title |
| 131-255 | Reserve |

### Window Allocation

| `$5130` window | Physical banks | Use |
|---:|---:|---|
| 0 | 0-63 | Gameplay backgrounds |
| 1 | 64-127 | Sprites and status bar |
| 2 | 128-191 | Title |
| 3 | 192-255 | Expansion |

### Placement Rules

| Resource | Rule |
|---|---|
| ExAttr bank field | Six per-cell bank bits |
| Global window | `$5130` selects one 256 KiB background window |
| Texture IDs | Four-bit map field, 16 slots |
| Full-map texture occupancy | 16 slots |
| Immediate gameplay expansion | Bank 63 |
| Cross-window content | Schedule a window transition or duplicate shared resources |

## WRAM

### Active Bank Layout

| Range | Bytes | Allocation |
|---|---:|---|
| `$6000-$69FF` | 2,560 | Double compose buffers |
| `$6A00-$6A0F` | 16 | Frame metadata, player state, active bitset |
| `$6A10-$6A1E` | 15 | HUD face, level, SFX, and previous-player state |
| `$6A1F-$6A27` | 9 | Available |
| `$6A28-$6AFE` | 215 | HUD, weapon, thing, combat, and monster state |
| `$6AFF` | 1 | Available |
| `$6B00-$76FF` | 3,072 | Three four-page OAM sets |
| `$7700-$77FF` | 256 | Mutable sector ceiling shadow |
| `$7800-$7832` | 51 | Door and lift state |
| `$7833-$78FF` | 205 | Available |
| `$7900-$79FF` | 256 | Mutable sector floor shadow |
| `$7A00-$7EFF` | 1,280 | Available |
| `$7F00-$7F12` | 19 | Music and audio state |
| `$7F13-$7FFF` | 237 | Available |

| Active-bank total | Bytes |
|---|---:|
| Allocated | Approximately 6,460 |
| Available | Approximately 1,732 |

### Bank Model

| Property | Current value |
|---|---|
| Visible window | `$6000-$7FFF` |
| Selected bank | 0 |
| Reserve banks | 1-3 |
| Reserve capacity | 24 KiB |
| Allocation style | Fixed absolute addresses |
| Bank register | `$5113` |

### Allocation Policy

| Priority | Action |
|---:|---|
| 1 | Keep compose, OAM, audio, and interrupt-visible state in bank 0 |
| 2 | Place cold mutable data in banks 1-3 |
| 3 | Wrap bank transitions with interrupt-safe save and restore |
| 4 | Migrate fixed addresses into linker-tracked segments as layouts grow |

## Source Of Record

| File | Data |
|---|---|
| `src/header.s` | ROM and RAM declarations |
| `cfg/nesdoom.cfg` | PRG, CHR, and linker placement |
| `src/globals.inc` | WRAM addresses and bank constants |
| `tools/tilegen.py` | CHR layout and generated extent |
| `tools/mapconv.py` | Map bank, texture-slot, and variant budgets |
| `nesdoom-e1m1.dbg` | Trimmed-build segment occupancy |
| `nesdoom-e1m1-full.dbg` | Full-build segment occupancy |
