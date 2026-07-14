; NMI (scanline 241).
; M3+: vblank share of the band pusher, then full register restore. E1M1 also
; refreshes static weapon OAM because the long letterbox blank stops OAM DRAM
; refresh long enough to risk decay on hardware.
; E1M1 pushes two columns because it also installs a buffered wall palette;
; the micro-map pushes three.
; The scanline IRQ must be re-armed here every frame: MMC5 in-frame detection
; stops while rendering is disabled, so after the letterbox the NMI is the
; only guaranteed wake-up.
.include "zeropage.inc"
.include "mmc5.inc"
.include "globals.inc"

.import push_run
.ifdef E1M1
.import sec_pal
.endif
.export nmi_handler

.segment "FIXED"

nmi_handler:
    pha
    txa
    pha
    tya
    pha

    inc frame_cnt

.ifdef E1M1
    ; OAM is dynamic RAM and the long letterbox blank exceeds safe retention.
    ; Refresh the unchanged static weapon page once per frame.
    lda #0
    sta $2003
    lda #$02
    sta $4014
.endif

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
    ; Resolve the palette owned by the last fully displayed frame.  This also
    ; restores from the HUD set installed by the line-160 split.
    lda #0
    sta pal_ptr+1
    lda pal_sec
    sta pal_active
    .repeat 4
    asl
    rol pal_ptr+1
    .endrepeat
    clc
    adc #<sec_pal
    sta pal_ptr
    lda pal_ptr+1
    adc #>sec_pal
    sta pal_ptr+1
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
