.include "zeropage.inc"
.include "mmc5.inc"
.include "globals.inc"

.ifdef E1M1

.export update_face, upload_face

FACE_PAIN_TIME = 60
FACE_IDLE_TIME = 30
FACE_DEAD = 12

.segment "FIXED"

.macro HUD_CALL target
    lda prg8000_sh
    pha
    lda #HUD_CODE_BANK
    sta prg8000_sh
    sta MMC5_PRG_8000
    jsr target
    pla
    sta prg8000_sh
    sta MMC5_PRG_8000
    rts
.endmacro

upload_face:
    HUD_CALL upload_face_impl

.segment "CODE"

update_face:
    lda PL_HEALTH
    bne @alive
    lda ENEMY_HITS
    sta FACE_HIT_SEEN
    lda #0
    sta FACE_TIMER
    lda #FACE_DEAD
    sta FACE_WANT
    rts

@alive:
    lda ENEMY_HITS
    cmp FACE_HIT_SEEN
    beq @no_hit
    sta FACE_HIT_SEEN
    lda #FACE_PAIN_TIME
    sta FACE_TIMER
    lda #0
    sta FACE_IDLE_TIMER
    sta FACE_IDLE_PHASE
    jsr face_tier
    clc
    adc #5                  ; tiered STFKILL damage reaction
    sta FACE_WANT
    rts

@no_hit:
    lda FACE_TIMER
    beq @idle
    dec FACE_TIMER
    bne @done               ; retain the frame chosen by the damage event
    jsr face_tier
    bne @tiered_idle
    lda #0                  ; healthy pain expires to centered STFST01 now
    sta FACE_WANT
    sta FACE_IDLE_TIMER
    sta FACE_IDLE_PHASE
    rts

@idle:
    jsr face_tier
    bne @tiered_idle
    inc FACE_IDLE_TIMER
    lda FACE_IDLE_TIMER
    cmp #FACE_IDLE_TIME
    bcc @done
    lda #0
    sta FACE_IDLE_TIMER
    inc FACE_IDLE_PHASE
    lda FACE_IDLE_PHASE
    cmp #3
    bcc :+
    lda #0
    sta FACE_IDLE_PHASE
:   tax
    lda healthy_idle_frame,x
    sta FACE_WANT
@done:
    rts

@tiered_idle:
    sta FACE_WANT
    lda #0
    sta FACE_IDLE_TIMER
    sta FACE_IDLE_PHASE
    rts

; A = pain tier: 0 for 80+, then one tier per 20 health down to 1.
face_tier:
    lda PL_HEALTH
    cmp #80
    bcs @tier0
    cmp #60
    bcs @tier1
    cmp #40
    bcs @tier2
    cmp #20
    bcs @tier3
    lda #4
    rts
@tier0:
    lda #0
    rts
@tier1:
    lda #1
    rts
@tier2:
    lda #2
    rts
@tier3:
    lda #3
    rts

healthy_idle_frame:
    .byte 0, 10, 11

.segment "HUDCODE"

upload_face_impl:
    lda FACE_WANT
    .repeat 4
    asl
    .endrepeat
    sta nmi_hud_value
    lda #%10001000          ; NMI on, increment-1
    sta $2000
    lda #$22
    ldx #$AE
    jsr upload_face_row
    lda #$22
    ldx #$CE
    jsr upload_face_row
    lda #$22
    ldx #$EE
    jsr upload_face_row
    lda #$23
    ldx #$0E
    jsr upload_face_row
    lda FACE_WANT
    sta FACE_SHOWN
    rts

; A/X = VRAM high/low. Frames are contiguous 16-tile blocks in CHR bank 127.
upload_face_row:
    sta nmi_hud_hund
    bit $2002
    lda nmi_hud_hund
    sta $2006
    stx $2006
    ldx #4
@tile:
    lda nmi_hud_value
    sta $2007
    inc nmi_hud_value
    dex
    bne @tile
    rts

.endif
