; NMI (scanline 241).
; M3+: vblank share of the band pusher, then full register restore. E1M1 also
; refreshes buffered weapon/world OAM because the long letterbox blank stops
; OAM DRAM refresh long enough to risk decay on hardware.
; E1M1 normally pushes two columns because it also installs a buffered wall
; palette; dynamic-HUD frames push one. The micro-map pushes three.
; The scanline IRQ must be re-armed here every frame: MMC5 in-frame detection
; stops while rendering is disabled, so after the letterbox the NMI is the
; only guaranteed wake-up.
.include "zeropage.inc"
.include "mmc5.inc"
.include "globals.inc"

.import push_run
.ifdef E1M1
.import sec_pal, hud_glyph_top, hud_glyph_bottom
.import weapon_chr_page_lo, weapon_chr_page_hi
.import audio_tick
.import update_face, upload_face
.endif
.export nmi_handler

.segment "FIXED"

nmi_handler:
    pha
    txa
    pha
    tya
    pha

.ifdef E1M1
    ; The status IRQ leaves ExAttr in HUD window 1. Restore the gameplay
    ; background window while rendering is blank.
    lda #0
    sta MMC5_CHR_HI
.endif

    inc frame_cnt
.ifndef E1M1
    jsr read_input
.endif

.ifdef E1M1
    ; Weapon state uses the prior frame's stable sample. Polling immediately
    ; after OAM DMA gives controller reads a DMC-safe CPU/APU phase.
    jsr update_weapon
    jsr select_weapon_chr

    ; OAM is dynamic RAM and the long letterbox blank exceeds safe retention.
    ; Select the live weapon frame within the published four-page set.
    lda #0
    sta $2003
    lda oam_dma_set
    clc
    adc WEAPON_FRAME
    sta $4014
    jsr read_input
    jsr update_face
.endif

.ifndef M2DEMO
    ; vblank push window — but only if we didn't interrupt a push already in
    ; flight (a late-running letterbox push shares all the pusher state; the
    ; register restore below still leaves it consistent to resume)
    lda push_active
    bne @skippush
.ifdef E1M1
    lda HUD_DIRTY
    beq @face_check
    jsr upload_hud
    lda #0              ; six HUD runs consume the full column-push budget
    jmp @set_quota
@face_check:
    lda FACE_WANT
    cmp FACE_SHOWN
    beq @normal_quota
    jsr upload_face
    lda #0              ; face upload consumes this frame's push headroom
    jmp @set_quota
@normal_quota:
    lda #NMI_QUOTA
@set_quota:
    sta push_quota
    lda #%10001100      ; push_run requires increment-32
    sta $2000
.else
    lda #NMI_QUOTA
    sta push_quota
.endif
    lda #EXRAM_MODE_RAM
    sta MMC5_EXRAM_MODE
.ifndef E1M1
    lda #%10001100      ; NMI on, inc-32
    sta $2000
.endif
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
.ifdef E1M1
    ; PPU-critical work is complete. Audio may extend into the pre-render line
    ; without consuming the tightly budgeted VRAM-write window.
    jsr audio_tick
.endif

    pla
    tay
    pla
    tax
    pla
    rti

; Poll once per NMI so brief taps are retained even during a long render pass.
read_input:
    lda joy1
    sta joy1_prev
    lda #0
    sta joy1
    lda #1
    sta $4016
    lda #0
    sta $4016
    ldx #8
@bit:
    lda $4016
    lsr
    ror joy1
    dex
    bne @bit
    lda joy1_prev
    eor #$FF
    and joy1
    and #$02            ; B is edge-triggered Use
    ora joy_latched
    sta joy_latched
    lda joy1
    and #$F0
    ora joy_latched
    sta joy_latched
    rts

.ifdef E1M1

select_weapon_chr:
    ldx WEAPON_FRAME
    lda weapon_chr_page_hi,x
    sta MMC5_CHR_HI
    lda weapon_chr_page_lo,x
    sta MMC5_CHR_SPR0+WEAPON_SPRITE_PAGE_FIRST
    clc
    adc #1
    sta MMC5_CHR_SPR0+WEAPON_SPRITE_PAGE_FIRST+1
    lda #0
    sta MMC5_CHR_HI
    rts

; Four-state pistol sequence: flash B, recoil C, recovery B, idle A.
update_weapon:
    lda WEAPON_TIMER
    beq @ready
    dec WEAPON_TIMER
    bne @done
    lda WEAPON_FRAME
    cmp #1
    bne :+
    lda #2
    sta WEAPON_FRAME
    lda #4
    sta WEAPON_TIMER
    rts
:   cmp #2
    bne :+
    lda #3
    sta WEAPON_FRAME
    lda #4
    sta WEAPON_TIMER
    rts
:   lda #0
    sta WEAPON_FRAME
@ready:
    lda WEAPON_FRAME
    bne @done
    lda joy1
    and #$01            ; A fires; held A repeats after recovery
    beq @done
    lda PL_AMMO
    bne :+
    lda #1
    sta EMPTY_SOUND_PENDING
    rts
:
    dec PL_AMMO
    inc SHOT_COUNT
    lda #1
    sta HUD_DIRTY
    sta WEAPON_FRAME
    lda #5
    sta WEAPON_TIMER
    lda #1
    sta PISTOL_SOUND_PENDING
@done:
    rts

; Convert A in 0..200 into right-aligned glyph indices. Zero remains visible.
hud_convert:
    sta nmi_hud_value
    lda #10
    sta nmi_hud_hund
    sta nmi_hud_tens
    lda nmi_hud_value
    ldx #0
@hundreds:
    cmp #100
    bcc @tens
    sec
    sbc #100
    inx
    bne @hundreds
@tens:
    cpx #0
    beq :+
    stx nmi_hud_hund
:   ldy #0
@tens_loop:
    cmp #10
    bcc @ones
    sec
    sbc #10
    iny
    bne @tens_loop
@ones:
    sta nmi_hud_ones
    cpy #0
    bne @store_tens
    lda nmi_hud_hund
    cmp #10
    beq @converted
@store_tens:
    sty nmi_hud_tens
@converted:
    rts

hud_line_top:
    lda #<hud_glyph_top
    sta nmi_glyph_ptr
    lda #>hud_glyph_top
    sta nmi_glyph_ptr+1
    jmp hud_line

hud_line_bottom:
    lda #<hud_glyph_bottom
    sta nmi_glyph_ptr
    lda #>hud_glyph_bottom
    sta nmi_glyph_ptr+1

; X = low VRAM address, nmi_hud_value = run length (3 or 4).
hud_line:
    bit $2002
    lda #$22
    sta $2006
    stx $2006
    ldy nmi_hud_hund
    lda (nmi_glyph_ptr),y
    sta $2007
    ldy nmi_hud_tens
    lda (nmi_glyph_ptr),y
    sta $2007
    ldy nmi_hud_ones
    lda (nmi_glyph_ptr),y
    sta $2007
    lda nmi_hud_value
    cmp #4
    bne @done
    ldy #11
    lda (nmi_glyph_ptr),y
    sta $2007
@done:
    rts

upload_hud:
    lda #%10001000      ; increment-1 for six short horizontal runs
    sta $2000
    lda PL_AMMO
    jsr hud_convert
    lda #3
    sta nmi_hud_value
    ldx #$A1
    jsr hud_line_top
    ldx #$C1
    jsr hud_line_bottom
    lda PL_HEALTH
    jsr hud_convert
    lda #4
    sta nmi_hud_value
    ldx #$A6
    jsr hud_line_top
    ldx #$C6
    jsr hud_line_bottom
    lda PL_ARMOR
    jsr hud_convert
    lda #4
    sta nmi_hud_value
    ldx #$B3
    jsr hud_line_top
    ldx #$D3
    jsr hud_line_bottom
    lda #0
    sta HUD_DIRTY
    rts

.endif
