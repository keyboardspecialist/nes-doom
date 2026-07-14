; Shared constants: compose buffers, pusher banks, push quotas.
.ifndef GLOBALS_INC
GLOBALS_INC = 1

; Double-buffered compose shadows in PRG-RAM (column-major: [col*20 + row]).
; Fixed addresses because the unrolled pushers bake them into absolute operands.
BUFA_NT = $6000     ; 640 bytes
BUFA_EX = $6280     ; 640 bytes
BUFB_NT = $6500
BUFB_EX = $6780
; Camera-sector palette metadata travels with each compose buffer.  The
; pusher publishes it only after the final column reaches the nametable.
BUFA_PAL_SEC = $6A00

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
;   E1M1 vblank: entry ~30 + OAM DMA ~520 + 2x410 + palette/restore ~350
;     = ~1720 of 2273; measured rendering restore is scanline 249-257
STATUS_LINE = 160
BLANK_LINE  = 199
VIEW_MASK   = %00011110  ; BG + sprites in the 160-line view
STATUS_MASK = %00001110  ; BG only below the view
SPLIT2_CMP  = 36    ; E1M1: phase-1 compare RELATIVE to the counter restart
                    ; after the line-160 palette-swap blank (measured)
IRQ_QUOTA = 10
.ifdef E1M1
NMI_QUOTA = 2       ; vblank also loads the per-sector palette set (~210 cyc)
.else
NMI_QUOTA = 3
.endif

VIEW_ROWS = 20
VIEW_COLS = 32
PF_CLIP   = 36      ; angle-gate clip half-angle: 32 (45 deg) + atan slack;
                    ; must match the angcol_tbl domain in tools/tablegen.py

; CHR bank layout (must match tools/tilegen.py): variable banks for WAD
; textures, six banks per synthetic texture, then the flats/status bank.
.ifdef E1M1
FLAT_BANK = 60      ; WAD textures fill banks 0-59 (variable banks/texture)
EDGE_BANK = 62      ; 128 sloped silhouette tiles (HUD sits at 61)
WEAPON_BANK = 63    ; static weapon sprite tiles
.else
FLAT_BANK = 12      ; 2 synthetic textures, 6 banks each
.endif
SLICES_PER_TEX = 109    ; sum of per-class phase counts

.endif
