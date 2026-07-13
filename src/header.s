; NES 2.0 header — mapper 5 (MMC5), 128KB PRG-ROM, 1MB CHR-ROM, 32KB PRG-RAM.
; Note: no historical MMC5 board shipped 1MB CHR; NES 2.0-legal, emulator-targeted.
.segment "HEADER"
    .byte "NES", $1A
    .byte 8             ; PRG-ROM: 8 x 16KB = 128KB
    .byte $80           ; CHR-ROM: 128 x 8KB = 1MB
    .byte $50           ; mapper 5 low nibble, horizontal mirroring bit (MMC5 overrides)
    .byte $08           ; NES 2.0 identifier, mapper high nibble 0
    .byte $00           ; mapper bits 8-11 / submapper
    .byte $00           ; PRG/CHR ROM size high bits
    .byte $09           ; PRG-RAM (volatile): 64 << 9 = 32KB
    .byte $00           ; CHR-RAM: none
    .byte $00           ; timing: NTSC
    .byte $00, $00, $00
