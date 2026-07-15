; Forced-blank startup title. NMI and the MMC5 scanline IRQ remain disabled,
; so this can temporarily own ExRAM, CHR window 2, and the $8000 PRG window.
.include "zeropage.inc"
.include "mmc5.inc"
.include "globals.inc"

.ifdef E1M1
.import title_nt, title_ex, title_palettes
.export show_title

.segment "FIXED"

show_title:
    lda #0
    sta MMC5_IRQ_EN
    sta MMC5_IRQ_CMP
    lda MMC5_IRQ_EN     ; acknowledge an IRQ retained across a soft reset
    lda #TITLE_PRG_BANK
    sta MMC5_PRG_8000
    sta prg8000_sh

    ; Upload the four background palettes.
    bit $2002
    lda #$3F
    sta $2006
    lda #$00
    sta $2006
    ldx #0
@palette:
    lda title_palettes,x
    sta $2007
    inx
    cpx #16
    bne @palette

    ; Upload 960 tile bytes, then clear the unused attribute table. MMC5
    ; extended attributes supply both palette and CHR bank per cell.
    lda #<title_nt
    sta m2_ptr
    lda #>title_nt
    sta m2_ptr+1
    bit $2002
    lda #$20
    sta $2006
    lda #$00
    sta $2006
    jsr @copy_960_ppu
    ldx #64
    lda #0
@clear_attributes:
    sta $2007
    dex
    bne @clear_attributes

    ldx #0
@copy_exattr:
    lda title_ex,x
    sta EXRAM,x
    lda title_ex+$100,x
    sta EXRAM+$100,x
    lda title_ex+$200,x
    sta EXRAM+$200,x
    cpx #192
    bcs @skip_tail
    lda title_ex+$300,x
    sta EXRAM+$300,x
@skip_tail:
    inx
    bne @copy_exattr

    lda #TITLE_CHR_WINDOW
    sta MMC5_CHR_HI
    mmc5_exram_attr_mode
    bit $2002
    lda #0
    sta $2005
    sta $2005
@first_vblank:
    bit $2002
    bpl @first_vblank
    lda #%00001000      ; NMI off, increment 1
    sta $2000
    lda #%00001010      ; background and leftmost background pixels on
    sta $2001

@wait_start:
@leave_vblank:
    bit $2002
    bmi @leave_vblank
@next_vblank:
    bit $2002
    bpl @next_vblank
    jsr @read_pad
    lda joy1
    and #$08
    beq @wait_start

    ; Start was sampled in vblank. Restore the reset-time state expected by
    ; the existing gameplay initialization before returning to it.
    lda #0
    sta $2001
    sta $2000
    sta MMC5_IRQ_EN
    sta MMC5_IRQ_CMP
    lda MMC5_IRQ_EN     ; title rendering may have latched a pending IRQ
    lda #0
    sta MMC5_CHR_HI
    sta joy1
    sta joy1_prev
    sta joy_latched
    mmc5_exram_cpu_mode
    lda #0
    tax
@clear_exram:
    sta EXRAM,x
    sta EXRAM+$100,x
    sta EXRAM+$200,x
    sta EXRAM+$300,x
    inx
    bne @clear_exram
    lda #$80
    sta MMC5_PRG_8000
    sta prg8000_sh
    rts

@copy_960_ppu:
    ldx #3
@copy_page:
    ldy #0
@copy_byte:
    lda (m2_ptr),y
    sta $2007
    iny
    bne @copy_byte
    inc m2_ptr+1
    dex
    bne @copy_page
    ldy #0
@copy_tail:
    lda (m2_ptr),y
    sta $2007
    iny
    cpy #192
    bne @copy_tail
    rts

@read_pad:
    lda #0
    sta joy1
    lda #1
    sta $4016
    lda #0
    sta $4016
    ldx #8
@read_bit:
    lda $4016
    lsr
    ror joy1
    dex
    bne @read_bit
    rts
.endif
