# Memory Budgets

This document records the PRG-ROM, CHR-ROM, and WRAM budgets for the current
trimmed and full E1M1 builds, including the wall-collision and animated-door
work.

## Summary

- PRG-ROM capacity: 128 KiB in sixteen 8 KiB banks.
- Full E1M1 PRG use: 71,583 bytes, leaving 59,489 bytes overall.
- CHR-ROM capacity: 1 MiB.
- Generated CHR prefix: 536,576 bytes; the remaining 512,000 bytes are
  linker-filled zeros.
- Advertised volatile PRG-RAM: 32 KiB.
- Runtime WRAM use: bank 0 only, through the 8 KiB `$6000-$7FFF` window.
- Bank-0 WRAM reserved: approximately 6,190 bytes, leaving 2,002 bytes.
- Extended MMC5 WRAM is not currently banked or used.

## PRG-ROM

The cartridge contains sixteen 8 KiB PRG-ROM banks.

| Bank | Full E1M1 purpose | Used | Free |
|---:|---|---:|---:|
| 00 | LUTs | 8,123 | 69 |
| 01 | Common map and LUTs | 5,927 | 2,265 |
| 02 | Pusher A | 8,128 | 64 |
| 03 | Pusher B | 8,128 | 64 |
| 04 | Seg bank 0 | 8,184 | 8 |
| 05 | Seg bank 1 | 1,608 | 6,584 |
| 06 | Vertices and nodes | 5,908 | 2,284 |
| 07 | Title code and data | 1,936 | 6,256 |
| 08 | Music | 8,016 | 176 |
| 09 | HUD face upload code | 75 | 8,117 |
| 0A-0C | Unused | 0 | 24,576 total |
| 0D | Door code | 732 | 7,460 |
| 0E | Main code | 8,074 | 118 |
| 0F | Fixed code, DPCM, and vectors | 6,744 | 1,448 fragmented |

Full E1M1 uses 71,583 bytes and leaves 59,489 bytes overall. The trimmed
build uses approximately 56.1 KiB and leaves approximately 75.0 KiB.

### Placement Pressure

- Banks 0A-0C provide three completely unused 8 KiB ROM banks.
- Bank 04 has only eight bytes free and cannot hold additional full-map segs
  without changing the seg split.
- Main `CODE` in bank 0E has 118 bytes free.
- The contiguous fixed-code region before DPCM has 111 bytes free in the full
  build.
- Door bank 0D has approximately 7.3 KiB free.
- Pusher banks 02 and 03 intentionally have only 64 bytes free each.
- Music bank 08 has 176 bytes free.

Total free PRG-ROM is therefore not the immediate limitation. The main
constraint is placement in specific hot or fixed banks.

## CHR-ROM

The NES 2.0 header advertises 1 MiB of CHR-ROM. ld65 emits the complete 1 MiB
region because the linker memory area uses `fill=yes`.

| Measurement | Size |
|---|---:|
| Generated CHR prefix | 536,576 bytes / 524 KiB |
| Linker-filled tail | 512,000 bytes / 500 KiB |
| Total CHR-ROM | 1,048,576 bytes / 1 MiB |
| Highest allocated 4 KiB bank | 130 of 255 |

### CHR Layout

| 4 KiB banks | Purpose |
|---:|---|
| 0-42 | Wall texture slices |
| 43-59 | Half-row wall variants |
| 60 | Flat, status, and portal helpers |
| 61 | HUD source copy |
| 62 | Wall edge silhouettes |
| 63 | Free gameplay bank |
| 64-67 | World and weapon sprites |
| 68-124 | Unused gap |
| 125 | Runtime HUD copy |
| 126 | Unused |
| 127 | Thirteen 4x4 animated HUD face frames |
| 128-130 | Title |
| 131-255 | Unused linker-filled tail |

Approximately 740-748 KiB consists of completely zero 4 KiB banks, depending
on the build.

### Practical CHR Constraints

- Extended attributes provide six per-cell CHR bank bits.
- `$5130` selects a global 256 KiB CHR window.
- Gameplay uses window 0, the HUD uses window 1, and the title uses window 2.
- Texture IDs are four bits, limiting a map to 16 texture slots.
- Full E1M1 currently uses all 16 texture slots.
- Bank 63 is the easiest immediate 4 KiB gameplay expansion.
- The large unused tail is not automatically available for simultaneously
  visible gameplay textures. Using it requires another `$5130` window,
  resource duplication, or additional timed window switching.

## WRAM

The current NES 2.0 header advertises 32 KiB of volatile PRG-RAM:

```asm
.byte $09  ; 64 << 9 = 32 KiB volatile PRG-RAM
```

The engine selects bank 0 once during initialization:

```asm
lda #0
sta MMC5_RAM_BANK ; $5113
```

No runtime code subsequently changes `$5113`. Only bank 0 is used, and the
other three advertised 8 KiB banks remain unused.

### Bank-0 Layout

| Range | Bytes | Purpose |
|---|---:|---|
| `$6000-$69FF` | 2,560 | Double compose buffers |
| `$6A00-$6A0F` | 16 | Frame metadata, player state, active bitset |
| `$6A10-$6A15` | 6 | HUD face animation state |
| `$6A16-$6A27` | 18 | Free |
| `$6A28-$6AFE` | 215 | HUD, weapon, thing, combat, and monster state |
| `$6AFF` | 1 | Free |
| `$6B00-$76FF` | 3,072 | Three four-page OAM sets |
| `$7700-$77FF` | 256 | Mutable sector ceiling shadow |
| `$7800-$782D` | 46 | Door state and temporaries |
| `$782E-$7EFF` | 1,746 | Free |
| `$7F00-$7F12` | 19 | Music and audio state |
| `$7F13-$7FFF` | 237 | Free |

Bank 0 reserves approximately 6,190 bytes and leaves approximately 2,002
bytes free.

### Extended WRAM Status

Extended MMC5 WRAM is not currently used:

- The header advertises 32 KiB, not 128 KiB.
- The linker exposes only the visible 8 KiB `$6000-$7FFF` window.
- `$5113` remains fixed at bank 0.
- No data is allocated in the other advertised banks.
- Current WRAM addresses are absolute constants rather than linker-managed
  segments, so ld65 cannot detect overlap or overflow.

## Recommendations

1. Use free PRG-ROM banks 0A-0C for new systems and cold code.
2. Keep WRAM bank 0 for compose, OAM, audio, and interrupt-visible state.
3. Use the three already-advertised extra WRAM banks for cold mutable data
   before increasing the cartridge to 128 KiB WRAM.
4. Add interrupt-safe WRAM bank-switch wrappers with explicit save and restore
   behavior.
5. Convert absolute WRAM allocations into linker-tracked segments.
6. Use CHR bank 63 first. Larger gameplay CHR additions require deliberate
   `$5130` window scheduling rather than simply placing data in the unused
   500 KiB tail.

## Relevant Files

- `src/header.s`: NES 2.0 PRG, CHR, and RAM declarations.
- `cfg/nesdoom.cfg`: linker memory areas and PRG/CHR bank placement.
- `src/main.s`: MMC5 PRG, CHR, and WRAM initialization.
- `src/mmc5.inc`: MMC5 register definitions.
- `src/globals.inc`: absolute WRAM layout and bank constants.
- `tools/tilegen.py`: generated CHR layout.
- `tools/mapconv.py`: map, texture-slot, and variant budgets.
- `nesdoom-e1m1.dbg`: linked trimmed-build segment occupancy.
- `nesdoom-e1m1-full.dbg`: linked full-build segment occupancy.
