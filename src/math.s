; Fixed-point math on the MMC5 multiplier ($5205/$5206: unsigned 8x8->16,
; result readable immediately). Main-thread only — NMI/IRQ never touch the
; multiplier or the math zero-page block.
;
; mul16u: mul_r(32) = mul_a(16) * mul_b(16), unsigned, ~130 cycles
; mul16s: same, signed (sign-magnitude wrapper)
.include "zeropage.inc"
.include "mmc5.inc"

.import atan_tbl, log2_mant, atan_log_tbl, recip_col_lo, recip_col_hi
.export mul16u, mul16s, mul16s9, mul16s8u
.export mul8u16u, mul8s16u, mul8s16s, mul16s16u
.export atan2_hi, atan2_pg

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

; Signed 16 x unsigned 8.  Two MMC5 partials, then correct the unsigned
; interpretation when A is negative.  mul_b+1 is ignored.
mul16s8u:
    lda mul_a
    sta MMC5_MULT_A
    lda mul_b
    sta MMC5_MULT_B
    lda MMC5_MULT_A
    sta mul_r
    lda MMC5_MULT_B
    sta mul_r+1
    lda mul_a+1
    sta MMC5_MULT_A
    lda MMC5_MULT_A
    clc
    adc mul_r+1
    sta mul_r+1
    lda MMC5_MULT_B
    adc #0
    sta mul_r+2
    lda #0
    sta mul_r+3
    lda mul_a+1
    bpl :+
    lda mul_r+2          ; unsigned(A)*B - (B<<16)
    sec
    sbc mul_b
    sta mul_r+2
    lda mul_r+3
    sbc #0
    sta mul_r+3
:   rts

; Signed 16 x unsigned 16.  Reuse the four-part core and correct negative A.
mul16s16u:
    jsr mul16u
    lda mul_a+1
    bpl :+
    lda mul_r+2          ; unsigned(A)*B - (B<<16)
    sec
    sbc mul_b
    sta mul_r+2
    lda mul_r+3
    sbc mul_b+1
    sta mul_r+3
:   rts

; Unsigned low byte of A x unsigned B16.  Internal 24-bit core.
mul8u16u:
    lda mul_a
    sta MMC5_MULT_A
    lda mul_b
    sta MMC5_MULT_B
    lda MMC5_MULT_A
    sta mul_r
    lda MMC5_MULT_B
    sta mul_r+1
    lda mul_b+1
    sta MMC5_MULT_B
    lda MMC5_MULT_A
    clc
    adc mul_r+1
    sta mul_r+1
    lda MMC5_MULT_B
    adc #0
    sta mul_r+2
    lda #0
    sta mul_r+3
    rts

; Signed 8 x unsigned 16.  The signed byte is in mul_a low.
mul8s16u:
    jsr mul8u16u
    lda mul_a
    bpl :+
    lda mul_r+1          ; unsigned(A8)*B - (B<<8)
    sec
    sbc mul_b
    sta mul_r+1
    lda mul_r+2
    sbc mul_b+1
    sta mul_r+2
    lda mul_r+3
    sbc #0
    sta mul_r+3
:   rts

; Signed 8 x signed 16.  Correct both unsigned operand interpretations.
mul8s16s:
    jsr mul8u16u
    lda mul_a
    bpl :+
    lda mul_r+1
    sec
    sbc mul_b
    sta mul_r+1
    lda mul_r+2
    sbc mul_b+1
    sta mul_r+2
    lda mul_r+3
    sbc #0
    sta mul_r+3
:   lda mul_b+1
    bpl @s16done
    lda mul_r+2          ; subtract unsigned(A8)<<16
    sec
    sbc mul_a
    sta mul_r+2
    lda mul_r+3
    sbc #0
    sta mul_r+3
    lda mul_a
    bpl @s16done
    inc mul_r+3          ; both negative: restore the +2^24 cross term
@s16done:
    rts

; Signed 16 x signed 9 trig factor (-256..+256).  Cardinal values use exact
; zero/shift paths; intermediate factors use the signed16 x unsigned8 core.
mul16s9:
    lda mul_b+1
    beq @positive8
    cmp #1
    beq @plus256
    ; Negative table values are $FF01..$FFFF and $FF00 (-256).
    lda mul_b
    beq @minus256
    eor #$FF
    clc
    adc #1
    sta mul_b
    jsr mul16s8u
    jmp neg_r
@positive8:
    lda mul_b
    beq zero_r
    jmp mul16s8u
@plus256:
    lda mul_b
    beq :+
    jmp mul16s           ; defensive fallback outside the trig-table domain
:
    jsr shift8_r
    rts
@minus256:
    jsr shift8_r
    jmp neg_r

zero_r:
    lda #0
    sta mul_r
    sta mul_r+1
    sta mul_r+2
    sta mul_r+3
    rts

shift8_r:
    lda #0
    sta mul_r
    lda mul_a
    sta mul_r+1
    lda mul_a+1
    sta mul_r+2
    bpl :+
    lda #$FF
    bne :++
:   lda #0
:   sta mul_r+3
    rts

neg_r:
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
    rts

; ---------------------------------------------------------------------------
; atan2_hi: angle of (rt_dx, rt_dy) in BAM high-byte units (256 per circle,
; CCW, 0 = +x). Fold into the first octant, then use the difference between
; compact Q4 log2 magnitudes to look up atan(2^-difference).
; Returns A = angle with C clear. C set = |dx| and |dy| both < 256 (16 world
; units), where quantized angles are unsuitable for culling and the caller
; must fall back to the exact path.
; Clobbers ttx, ttz, mtmp, tptr, mul regs, at_sx/at_sy/at_sw, X, Y.
; ---------------------------------------------------------------------------
atan2_hi:
    ldx #0
    lda rt_dx+1
    bpl @xpos
    inx
    sec
    lda #0
    sbc rt_dx
    sta ttx
    lda #0
    sbc rt_dx+1
    sta ttx+1
    jmp @dy
@xpos:
    lda rt_dx
    sta ttx
    lda rt_dx+1
    sta ttx+1
@dy:
    stx at_sx
    ldx #0
    lda rt_dy+1
    bpl @ypos
    inx
    sec
    lda #0
    sbc rt_dy
    sta ttz
    lda #0
    sbc rt_dy+1
    sta ttz+1
    jmp @mm
@ypos:
    lda rt_dy
    sta ttz
    lda rt_dy+1
    sta ttz+1
@mm:
    stx at_sy
    ; min -> mul_a, max -> mtmp; at_sw = 1 when |dy| > |dx|
    lda ttz+1
    cmp ttx+1
    bne :+
    lda ttz
    cmp ttx
:   bcs @ybig
    lda #0
    sta at_sw
    lda ttz
    sta mul_a
    lda ttz+1
    sta mul_a+1
    lda ttx
    sta mtmp
    lda ttx+1
    sta mtmp+1
    jmp @norm
@ybig:
    lda #1
    sta at_sw
    lda ttx
    sta mul_a
    lda ttx+1
    sta mul_a+1
    lda ttz
    sta mtmp
    lda ttz+1
    sta mtmp+1
@norm:
    lda mtmp+1
    bne :+
    sec                 ; max < 256 -> too close, ratio unreliable
    rts
:   ; Normalize max to $80xx..$FFxx, applying the same shifts to min.
    bmi @max_norm
@max_loop:
    asl mul_a
    rol mul_a+1
    asl mtmp
    rol mtmp+1
    bpl @max_loop
@max_norm:
    ldx #0
    lda mul_a+1
    beq @angle_zero      ; min/max < 1/128: rounded first-octant angle is zero
    bmi @min_norm
@min_loop:
    inx
    asl mul_a
    rol mul_a+1
    bpl @min_loop
@min_norm:
    ldy mtmp+1
    lda log2_mant-$80,y
    sta ttz              ; Q4 log mantissa of max
    ldy mul_a+1
    lda log2_mant-$80,y
    sta ttx              ; Q4 log mantissa of min
    txa
    .repeat 4
    asl
    .endrepeat           ; exponent difference * 16
    clc
    adc ttz
    sec
    sbc ttx
    cmp #102
    bcs @angle_zero
    tay
    lda atan_log_tbl,y
    jmp angle_fold_base
@angle_zero:
    lda #0
    jmp angle_fold_base

; angle_fold: A = ratio index (0..255) -> A = octant-folded angle, C clear.
; Uses at_sx/at_sy/at_sw set by the caller.
angle_fold:
    tay
    lda atan_tbl,y      ; 0..32 (first half-octant angle)
angle_fold_base:
    sta mtmp+2
    lda at_sw
    beq :+
    lda #64             ; |dy| > |dx|: t = 64 - t
    sec
    sbc mtmp+2
    sta mtmp+2
:   lda at_sx
    bne @xneg
    lda at_sy
    bne @q4
    lda mtmp+2          ; +x +y: t
    clc
    rts
@q4:
    lda #0              ; +x -y: -t
    sec
    sbc mtmp+2
    clc
    rts
@xneg:
    lda at_sy
    bne @q3
    lda #128            ; -x +y: 128 - t
    sec
    sbc mtmp+2
    clc
    rts
@q3:
    lda #128            ; -x -y: 128 + t
    clc
    adc mtmp+2
    clc
    rts

; ---------------------------------------------------------------------------
; atan2_pg: angle of (mtmp+2, mtmp+3) — SIGNED page deltas (16 world units
; per page) — in BAM high-byte units. Ratio index = min * recip_col[max]
; >> 8 = 256*min/max on the raw MMC5 multiplier (two 8x8 products, no
; mul16u). C clear + A = angle; C set when max(|dx|,|dy|) < 4 pages: page
; granularity is too coarse that close, the caller must not cull.
; Clobbers ttx, ttz, mtmp, at_sx/at_sy/at_sw, X, Y.
; ---------------------------------------------------------------------------
atan2_pg:
    ldx #0
    lda mtmp+2
    bpl :+
    inx
    eor #$FF
    clc
    adc #1
:   sta ttx
    stx at_sx
    ldx #0
    lda mtmp+3
    bpl :+
    inx
    eor #$FF
    clc
    adc #1
:   sta ttz
    stx at_sy
    ldx #0              ; at_sw = 0: |dy| <= |dx|
    cmp ttx             ; A = |dy|
    bcc @xbig
    inx
    lda ttx             ; min = |dx|, max = |dy|
    ldy ttz
    jmp @ratio
@xbig:
    ldy ttx             ; min = |dy| (already in A), max = |dx|
@ratio:
    stx at_sw
    cpy #4
    bcs :+
    sec                 ; max < 4 pages: too close
    rts
:   sta MMC5_MULT_A     ; min
    lda recip_col_lo,y
    sta MMC5_MULT_B
    lda MMC5_MULT_B     ; hi byte of min * recip_lo
    sta mtmp
    lda recip_col_hi,y
    sta MMC5_MULT_B     ; min retained in $5205
    lda MMC5_MULT_B     ; hi byte of min * recip_hi: any bit -> ratio >= 1
    bne @sat
    lda MMC5_MULT_A     ; lo byte of min * recip_hi
    clc
    adc mtmp
    bcs @sat
    jmp angle_fold
@sat:
    lda #255
    jmp angle_fold

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
