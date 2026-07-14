; Shared constants: compose buffers, pusher banks, push quotas.
.ifndef GLOBALS_INC
GLOBALS_INC = 1

; Double-buffered compose shadows in PRG-RAM (column-major: [col*20 + row]).
; Fixed addresses because the unrolled pushers bake them into absolute operands.
BUFA_NT = $6000     ; 640 bytes
BUFA_EX = $6280     ; 640 bytes
BUFB_NT = $6500
BUFB_EX = $6780

; Pusher code banks (PRG02/PRG03 mapped at $8000 via $5114; bit7 = ROM)
PUSH_BANK_A = $82
PUSH_BANK_B = $83
PUSH_JMP    = $8000     ; 32 x 3-byte JMP dispatch at the start of each pusher bank

; Screen split: view rows 0-19 (lines 0-159), status bar rows 20-24 (lines
; 160-199), letterbox lines 200-240. A column costs ~410 cycles including
; driver dispatch (measured the hard way: 9 columns + overhead exactly filled
; the old 207-241 window and collided with NMI).
;   letterbox window: IRQ@199 -> NMI@241 = 42 lines ~ 4775 cycles;
;     entry ~130 + 10x410 + exit ~15 = 4245, ends ~line 236 (5-line margin)
;   vblank: entry ~30 + DMA 514 + 3x410 + restore ~140 = 1914 of 2273
STATUS_LINE = 160
BLANK_LINE  = 199
IRQ_QUOTA = 10
NMI_QUOTA = 3

VIEW_ROWS = 20
VIEW_COLS = 32
PF_CLIP   = 36      ; angle-gate clip half-angle: 32 (45 deg) + atan slack;
                    ; must match the angcol_tbl domain in tools/tablegen.py

; CHR bank layout (must match tools/tilegen.py): 5 banks per texture
; (per-class isotropic texel widths, CLASS_TW), then the flats/status
; bank (tile 0 ceiling, tile 2 floor, tile 3 checker).
.ifdef E1M1
FLAT_BANK = 60      ; 12 WAD textures
.else
FLAT_BANK = 10      ; 2 synthetic textures
.endif
SLICES_PER_TEX = 101    ; sum of per-class phase counts (1+2+2+4*4+8*2+16*4)

.endif
