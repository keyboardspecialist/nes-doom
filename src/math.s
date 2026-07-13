; Fixed-point math on the MMC5 multiplier ($5205/$5206: unsigned 8x8->16,
; result readable immediately). Main-thread only — NMI/IRQ never touch the
; multiplier or the math zero-page block.
;
; mul16u: mul_r(32) = mul_a(16) * mul_b(16), unsigned, ~130 cycles
; mul16s: same, signed (sign-magnitude wrapper)
.include "zeropage.inc"
.include "mmc5.inc"

.export mul16u, mul16s

.segment "CODE"

; The MMC5 retains each factor register: writing one recomputes the product
; against the other unchanged. Ordering the partials al*bl -> al*bh -> ah*bh
; -> ah*bl means each step rewrites exactly ONE register (~20 cycles saved).
mul16u:
    lda mul_a
    sta MMC5_MULT_A
    lda mul_b
    sta MMC5_MULT_B
    lda MMC5_MULT_A     ; al*bl
    sta mul_r
    lda MMC5_MULT_B
    sta mul_r+1
    lda #0
    sta mul_r+3
    lda mul_b+1
    sta MMC5_MULT_B     ; al retained -> al*bh
    lda MMC5_MULT_A
    clc
    adc mul_r+1
    sta mul_r+1
    lda MMC5_MULT_B
    adc #0              ; cannot overflow (hi <= $FE)
    sta mul_r+2
    lda mul_a+1
    sta MMC5_MULT_A     ; bh retained -> ah*bh
    lda MMC5_MULT_A
    clc
    adc mul_r+2
    sta mul_r+2
    lda MMC5_MULT_B
    adc mul_r+3
    sta mul_r+3
    lda mul_b
    sta MMC5_MULT_B     ; ah retained -> ah*bl
    lda MMC5_MULT_A
    clc
    adc mul_r+1
    sta mul_r+1
    lda MMC5_MULT_B
    adc mul_r+2
    sta mul_r+2
    bcc :+
    inc mul_r+3
:   rts

mul16s:
    lda mul_a+1
    eor mul_b+1
    sta msign
    lda mul_a+1
    bpl :+
    jsr neg_a
:   lda mul_b+1
    bpl :+
    jsr neg_b
:   jsr mul16u
    lda msign
    bpl :+
    ; negate 32-bit result
    sec
    lda #0
    sbc mul_r
    sta mul_r
    lda #0
    sbc mul_r+1
    sta mul_r+1
    lda #0
    sbc mul_r+2
    sta mul_r+2
    lda #0
    sbc mul_r+3
    sta mul_r+3
:   rts

neg_a:
    sec
    lda #0
    sbc mul_a
    sta mul_a
    lda #0
    sbc mul_a+1
    sta mul_a+1
    rts

neg_b:
    sec
    lda #0
    sbc mul_b
    sta mul_b
    lda #0
    sbc mul_b+1
    sta mul_b+1
    rts
