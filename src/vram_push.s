; VRAM band pusher — the bandwidth heart of the design.
;
; Two banks of macro-generated, fully unrolled per-column routines (one bank
; per compose buffer). A column = 20 nametable bytes via $2007 in increment-32
; mode + 20 ExRAM bytes via absolute stores. ~332 cycles per column plus ~40
; of driver dispatch. Each bank: 96 bytes of jump tables + 32 x 251-byte
; routines = 8128 bytes.
;
; Caller contract (push_run): rendering blanked (or vblank), $5104 = %10,
; $2000 increment-32. Driver restores $5114 from prg8000_sh on exit.
.include "zeropage.inc"
.include "mmc5.inc"
.include "globals.inc"

.export push_run

.macro PUSH_SLOT c
    jmp .ident(.sprintf("cp%02d", c))
.endmacro

.macro GEN_PUSH_BANK bufnt, bufex
    ; push_col is logical progress through a bit-reversal schedule.  Spreading
    ; each source frame over the viewport avoids one wide old/new-frame seam.
    PUSH_SLOT 0
    PUSH_SLOT 16
    PUSH_SLOT 8
    PUSH_SLOT 24
    PUSH_SLOT 4
    PUSH_SLOT 20
    PUSH_SLOT 12
    PUSH_SLOT 28
    PUSH_SLOT 2
    PUSH_SLOT 18
    PUSH_SLOT 10
    PUSH_SLOT 26
    PUSH_SLOT 6
    PUSH_SLOT 22
    PUSH_SLOT 14
    PUSH_SLOT 30
    PUSH_SLOT 1
    PUSH_SLOT 17
    PUSH_SLOT 9
    PUSH_SLOT 25
    PUSH_SLOT 5
    PUSH_SLOT 21
    PUSH_SLOT 13
    PUSH_SLOT 29
    PUSH_SLOT 3
    PUSH_SLOT 19
    PUSH_SLOT 11
    PUSH_SLOT 27
    PUSH_SLOT 7
    PUSH_SLOT 23
    PUSH_SLOT 15
    PUSH_SLOT 31
    .repeat 32, c
    .ident(.sprintf("cp%02d", c)):
        lda #$20            ; VRAM $2000 + column, stepping +32 per write
        sta $2006
        lda #c
        sta $2006
        .repeat ::VIEW_ROWS, r
        lda bufnt + c*::VIEW_ROWS + r
        sta $2007
        .endrepeat
        .repeat ::VIEW_ROWS, r
        lda bufex + c*::VIEW_ROWS + r
        sta ::EXRAM + r*32 + c
        .endrepeat
        rts
    .endrepeat
.endmacro

.segment "PUSHA"
.proc push_bank_a
    GEN_PUSH_BANK BUFA_NT, BUFA_EX
.endproc

.segment "PUSHB"
.proc push_bank_b
    GEN_PUSH_BANK BUFB_NT, BUFB_EX
.endproc

.segment "FIXED"

; Push up to push_quota columns of the front buffer. When all 32 columns of a
; frame have been pushed, swaps to the back buffer if the composer has flagged
; it ready (back_ready) — so a window never idles while work exists.
push_run:
    lda #1                  ; NMI checks this before starting its own push
    sta push_active
    bit $2002               ; reset the $2006 write latch
@loop:
    lda push_quota
    beq @out
    lda push_col
    cmp #VIEW_COLS
    bcc @dopush
    lda back_ready          ; frame fully pushed; new one ready?
    beq @out
    lda front_buf
    eor #1
    sta front_buf
    lda #0
    sta push_col
    sta back_ready
    beq @loop               ; always taken
@dopush:
    ldx front_buf
    lda push_bank_tbl,x
    sta MMC5_PRG_8000
    lda push_col            ; vector = $8000 + schedule slot*3
    asl
    adc push_col
    sta push_vec
    lda #>PUSH_JMP
    sta push_vec+1
    jsr @indirect
    inc push_col
    lda push_col
    cmp #VIEW_COLS
    bne @next
.ifdef E1M1
    ; One-byte publication is NMI-safe even when the letterbox IRQ finishes
    ; this frame immediately before vblank.  NMI resolves the pointer itself.
    ldx front_buf
    lda BUFA_PAL_SEC,x
    sta pal_sec
.endif
    inc flip_cnt            ; full frame on screen
    bne @next
    inc flip_cnt_hi
@next:
    dec push_quota
    jmp @loop
@out:
    lda prg8000_sh          ; restore whatever bank the main thread had
    sta MMC5_PRG_8000
    lda #0
    sta push_active
    rts
@indirect:
    jmp (push_vec)

push_bank_tbl:
    .byte PUSH_BANK_A, PUSH_BANK_B
