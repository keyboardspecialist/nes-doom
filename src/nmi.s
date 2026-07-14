; NMI (scanline 241).
; M3+: OAM DMA first (sprites decay during the 33-line letterbox, so refresh
; immediately), then the vblank share of the band pusher, then full register
; restore. Budget: entry ~50 + DMA 514 + 4 columns ~1500 + restore ~120
; ≈ 2200 of the 2273-cycle vblank.
; The scanline IRQ must be re-armed here every frame: MMC5 in-frame detection
; stops while rendering is disabled, so after the letterbox the NMI is the
; only guaranteed wake-up.
.include "zeropage.inc"
.include "mmc5.inc"
.include "globals.inc"

.import push_run
.export nmi_handler

.segment "FIXED"

nmi_handler:
    pha
    txa
    pha
    tya
    pha

    inc frame_cnt

    lda #$02            ; OAM shadow page
    sta $4014

.ifndef M2DEMO
    ; vblank push window — but only if we didn't interrupt a push already in
    ; flight (a late-running letterbox push shares all the pusher state; the
    ; register restore below still leaves it consistent to resume)
    lda push_active
    bne @skippush
    lda #EXRAM_MODE_RAM
    sta MMC5_EXRAM_MODE
    lda #%10001100      ; NMI on, inc-32
    sta $2000
    lda #NMI_QUOTA
    sta push_quota
    jsr push_run
    lda #EXRAM_MODE_EXATTR
    sta MMC5_EXRAM_MODE
@skippush:
.endif

.ifdef E1M1
    ; load the camera sector's wall palette set (also restores from the
    ; HUD set the line-160 split swapped in). Rendering is still blanked.
    lda #%10001000      ; increment-1 for palette writes
    sta $2000
    bit $2002
    lda #$3F
    sta $2006
    lda #$00
    sta $2006
    ldy #0
@pal:
    lda (pal_ptr),y
    sta $2007
    iny
    cpy #16
    bne @pal
.endif
    ; restore scroll/control (t register was clobbered by $2006 writes)
    bit $2002
    lda ppu2000_sh
    sta $2000
    lda #0
    sta $2005
    sta $2005
    lda ppu2001_sh
    sta $2001           ; re-enable rendering (we are inside vblank)

    lda #160
    sta MMC5_IRQ_CMP
    lda #$80
    sta MMC5_IRQ_EN
    lda #0
    sta irq_phase

    pla
    tay
    pla
    tax
    pla
    rti
