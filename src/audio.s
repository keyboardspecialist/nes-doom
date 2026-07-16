; Bounded 60 Hz E1M1 music player. Expensive MUS parsing, voice allocation,
; pitch math, and percussion reduction are all done by tools/musicgen.py.
.include "zeropage.inc"
.include "mmc5.inc"
.include "globals.inc"

.export audio_init, audio_tick

.ifdef E1M1
.import music_stream, music_stream_end
.import music_apu_p1_lo, music_apu_p1_meta
.import music_apu_p2_lo, music_apu_p2_meta
.import music_tri_lo, music_tri_meta
.import music_mmc5_p1_lo, music_mmc5_p1_meta
.import music_mmc5_p2_lo, music_mmc5_p2_meta
.import music_noise_period, music_noise_length

.macro music_read
.local no_carry
    ldy #0
    lda (m2_ptr),y
    inc m2_ptr
    bne no_carry
    inc m2_ptr+1
no_carry:
.endmacro

.segment "FIXED"

audio_init:
    lda #0
    ldx #$12
@clear:
    sta MUSIC_DELAY,x
    dex
    bpl @clear
    lda #<music_stream
    sta MUSIC_PTR_LO
    lda #>music_stream
    sta MUSIC_PTR_HI

    lda #$40            ; four-step APU sequencer, frame IRQ inhibited
    sta $4017
    lda #$70            ; 25% guitar, halt length, constant volume 0
    sta $4000
    sta MMC5_PULSE1_CTRL
    lda #$B0            ; 50% guitar, halt length, constant volume 0
    sta $4004
    sta MMC5_PULSE2_CTRL
    lda #$08            ; pulse sweeps disabled
    sta $4001
    sta $4005
    lda #$80            ; triangle control set, linear reload 0 = silent
    sta $4008
    lda #$30
    sta $400C
    lda #$0F            ; base pulses, triangle, and noise enabled
    sta $4015
    lda #$03
    sta MMC5_AUDIO_EN
    rts

audio_tick:
    lda NOISE_HOLD
    beq :+
    dec NOISE_HOLD
    bne :+
    sta NOISE_OWNER
:
    lda MUSIC_DELAY
    beq audio_event
    dec MUSIC_DELAY
    jmp audio_sfx

audio_event:
    ; A late line-199 pusher can be interrupted in banked $8000 code. Never
    ; replace its bank; freeze music for this exceptional frame instead.
    lda push_active
    beq :+
    inc MUSIC_SKIP_COUNT
    jmp audio_sfx
:
    lda m2_ptr
    sta AUDIO_SAVE_PTR
    lda m2_ptr+1
    sta AUDIO_SAVE_PTR+1
    lda #MUSIC_PRG_BANK
    sta MMC5_PRG_8000
    lda MUSIC_PTR_LO
    sta m2_ptr
    lda MUSIC_PTR_HI
    sta m2_ptr+1

    music_read
    sta AUDIO_MASK
    and #$C0
    cmp #$C0
    beq @long_delay
    lsr
    lsr
    lsr
    lsr
    lsr
    lsr
    sta MUSIC_DELAY
    jmp audio_commands
@long_delay:
    music_read
    sec
    sbc #1
    sta MUSIC_DELAY

audio_commands:
    lda AUDIO_MASK
    and #$01
    beq :+
    music_read
    jsr apply_apu_p1
:
    lda AUDIO_MASK
    and #$02
    beq :+
    music_read
    jsr apply_apu_p2
:
    lda AUDIO_MASK
    and #$04
    beq :+
    music_read
    jsr apply_triangle
:
    lda AUDIO_MASK
    and #$08
    beq :+
    music_read
    jsr apply_percussion
:
    lda AUDIO_MASK
    and #$10
    beq :+
    music_read
    jsr apply_mmc5_p1
:
    lda AUDIO_MASK
    and #$20
    beq :+
    music_read
    jsr apply_mmc5_p2
:
    lda m2_ptr
    cmp #<music_stream_end
    bne @store_ptr
    lda m2_ptr+1
    cmp #>music_stream_end
    bne @store_ptr
    lda #<music_stream
    sta m2_ptr
    lda #>music_stream
    sta m2_ptr+1
    inc MUSIC_LOOP_COUNT
@store_ptr:
    lda m2_ptr
    sta MUSIC_PTR_LO
    lda m2_ptr+1
    sta MUSIC_PTR_HI
    lda AUDIO_SAVE_PTR
    sta m2_ptr
    lda AUDIO_SAVE_PTR+1
    sta m2_ptr+1
    lda prg8000_sh
    sta MMC5_PRG_8000
    inc MUSIC_EVENT_COUNT

audio_sfx:
    ; Preserve the old same-frame write order so existing sound signatures
    ; remain stable. The last/highest-priority request owns subsequent noise.
    lda NOISE_HOLD
    bne :+
    jmp @normal_sfx
:
    lda EXIT_SOUND_PENDING
    beq @held_explosion
    lda NOISE_OWNER
    cmp #8
    bcs :+
    jmp @exit
:
    lda #0
    sta EXIT_SOUND_PENDING
@held_explosion:
    lda EXPLOSION_SOUND_PENDING
    beq @held_enemy
    lda NOISE_OWNER
    cmp #7
    bcs :+
    jmp @explosion
:
    lda #0
    sta EXPLOSION_SOUND_PENDING
@held_enemy:
    lda ENEMY_SOUND_PENDING
    beq @held_pain
    lda NOISE_OWNER
    cmp #6
    bcs :+
    jmp @enemy
:
    lda #0
    sta ENEMY_SOUND_PENDING
@held_pain:
    lda PLAYER_PAIN_SOUND_PENDING
    beq @held_pistol
    lda NOISE_OWNER
    cmp #5
    bcs :+
    jmp @pain
:
    lda #0
    sta PLAYER_PAIN_SOUND_PENDING
@held_pistol:
    lda PISTOL_SOUND_PENDING
    beq @held_empty
    lda NOISE_OWNER
    cmp #4
    bcs :+
    jmp @pistol
:
    lda #0
    sta PISTOL_SOUND_PENDING
@held_empty:
    lda EMPTY_SOUND_PENDING
    beq @held_door
    lda NOISE_OWNER
    cmp #3
    bcs :+
    jmp @empty
:
    lda #0
    sta EMPTY_SOUND_PENDING
@held_door:
    lda DOOR_SOUND_PENDING
    beq @drop_held
    lda NOISE_OWNER
    cmp #2
    bcs @drop_held
    jmp @door
@drop_held:
    lda #0
    sta PICKUP_SOUND_PENDING
    sta DOOR_SOUND_PENDING
    sta EMPTY_SOUND_PENDING
    sta PISTOL_SOUND_PENDING
    sta PLAYER_PAIN_SOUND_PENDING
    sta ENEMY_SOUND_PENDING
    sta EXPLOSION_SOUND_PENDING
    rts
@normal_sfx:
    lda PICKUP_SOUND_PENDING
    beq @door
    lda #0
    sta PICKUP_SOUND_PENDING
    lda #$15
    sta $400C
    lda #$02
    sta $400E
    lda #$10
    sta $400F
    lda #2
    sta NOISE_HOLD
    lda #1
    sta NOISE_OWNER
@door:
    lda DOOR_SOUND_PENDING
    beq @empty
    lda #0
    sta DOOR_SOUND_PENDING
    lda #$16
    sta $400C
    lda #$0C
    sta $400E
    lda #$20
    sta $400F
    lda #8
    sta NOISE_HOLD
    lda #2
    sta NOISE_OWNER
@empty:
    lda EMPTY_SOUND_PENDING
    beq @pistol
    lda #0
    sta EMPTY_SOUND_PENDING
    lda #$12
    sta $400C
    lda #$01
    sta $400E
    lda #$08
    sta $400F
    lda #1
    sta NOISE_HOLD
    lda #3
    sta NOISE_OWNER
@pistol:
    lda PISTOL_SOUND_PENDING
    beq @pain
    lda #0
    sta PISTOL_SOUND_PENDING
    lda #$1B
    sta $400C
    lda #$04
    sta $400E
    lda #$18
    sta $400F
    lda #2
    sta NOISE_HOLD
    lda #4
    sta NOISE_OWNER
@pain:
    lda PLAYER_PAIN_SOUND_PENDING
    beq @enemy
    lda #0
    sta PLAYER_PAIN_SOUND_PENDING
    lda #$1C
    sta $400C
    lda #$08
    sta $400E
    lda #$28
    sta $400F
    lda #12
    sta NOISE_HOLD
    lda #5
    sta NOISE_OWNER
@enemy:
    lda ENEMY_SOUND_PENDING
    beq @explosion
    lda #0
    sta ENEMY_SOUND_PENDING
    lda #$18
    sta $400C
    lda #$06
    sta $400E
    lda #$24
    sta $400F
    lda #20
    sta NOISE_HOLD
    lda #6
    sta NOISE_OWNER
@explosion:
    lda EXPLOSION_SOUND_PENDING
    beq @exit
    lda #0
    sta EXPLOSION_SOUND_PENDING
    lda #$1F
    sta $400C
    lda #$0E
    sta $400E
    lda #$30
    sta $400F
    lda #40
    sta NOISE_HOLD
    lda #7
    sta NOISE_OWNER
@exit:
    lda EXIT_SOUND_PENDING
    beq @done
    lda #0
    sta EXIT_SOUND_PENDING
    lda #$1F
    sta $400C
    lda #$03
    sta $400E
    lda #$38
    sta $400F
    lda #30
    sta NOISE_HOLD
    lda #8
    sta NOISE_OWNER
@done:
    rts

apply_apu_p1:
    sta AUDIO_CMD
    and #$7F
    bne :+
    lda #$70
    sta $4000
    rts
:
    tax
    lda music_apu_p1_meta,x
    and #$78
    lsr
    lsr
    lsr
    ora #$70
    sta $4000
    lda music_apu_p1_lo,x
    sta $4002
    lda music_apu_p1_meta,x
    and #7
    sta AUDIO_DESIRED_HI
    lda AUDIO_CMD
    bmi @write
    lda AUDIO_DESIRED_HI
    cmp AUDIO_P0_HI
    beq @out
@write:
    lda AUDIO_DESIRED_HI
    sta AUDIO_P0_HI
    sta $4003
@out:
    rts

apply_apu_p2:
    sta AUDIO_CMD
    and #$7F
    bne :+
    lda #$B0
    sta $4004
    rts
:
    tax
    lda music_apu_p2_meta,x
    and #$78
    lsr
    lsr
    lsr
    ora #$B0
    sta $4004
    lda music_apu_p2_lo,x
    sta $4006
    lda music_apu_p2_meta,x
    and #7
    sta AUDIO_DESIRED_HI
    lda AUDIO_CMD
    bmi @write
    lda AUDIO_DESIRED_HI
    cmp AUDIO_P1_HI
    beq @out
@write:
    lda AUDIO_DESIRED_HI
    sta AUDIO_P1_HI
    sta $4007
@out:
    rts

apply_mmc5_p1:
    sta AUDIO_CMD
    and #$7F
    bne :+
    lda #$70
    sta MMC5_PULSE1_CTRL
    rts
:
    tax
    lda music_mmc5_p1_meta,x
    and #$78
    lsr
    lsr
    lsr
    ora #$70
    sta MMC5_PULSE1_CTRL
    lda music_mmc5_p1_lo,x
    sta MMC5_PULSE1_LO
    lda music_mmc5_p1_meta,x
    and #7
    sta AUDIO_DESIRED_HI
    lda AUDIO_CMD
    bmi @write
    lda AUDIO_DESIRED_HI
    cmp AUDIO_M0_HI
    beq @out
@write:
    lda AUDIO_DESIRED_HI
    sta AUDIO_M0_HI
    sta MMC5_PULSE1_HI
@out:
    rts

apply_mmc5_p2:
    sta AUDIO_CMD
    and #$7F
    bne :+
    lda #$B0
    sta MMC5_PULSE2_CTRL
    rts
:
    tax
    lda music_mmc5_p2_meta,x
    and #$78
    lsr
    lsr
    lsr
    ora #$B0
    sta MMC5_PULSE2_CTRL
    lda music_mmc5_p2_lo,x
    sta MMC5_PULSE2_LO
    lda music_mmc5_p2_meta,x
    and #7
    sta AUDIO_DESIRED_HI
    lda AUDIO_CMD
    bmi @write
    lda AUDIO_DESIRED_HI
    cmp AUDIO_M1_HI
    beq @out
@write:
    lda AUDIO_DESIRED_HI
    sta AUDIO_M1_HI
    sta MMC5_PULSE2_HI
@out:
    rts

apply_triangle:
    and #$7F
    bne :+
    lda #$80
    sta $4008
    rts
:
    tax
    lda #$FF
    sta $4008
    lda music_tri_lo,x
    sta $400A
    lda music_tri_meta,x
    sta $400B
    rts

apply_percussion:
    sta AUDIO_CMD
    and #$0F
    sta AUDIO_DESIRED_HI
    tax
    lda NOISE_HOLD
    bne @out
    lda PISTOL_SOUND_PENDING
    ora ENEMY_SOUND_PENDING
    ora EXPLOSION_SOUND_PENDING
    ora PICKUP_SOUND_PENDING
    ora PLAYER_PAIN_SOUND_PENDING
    ora DOOR_SOUND_PENDING
    ora EXIT_SOUND_PENDING
    ora EMPTY_SOUND_PENDING
    bne @out
    lda AUDIO_CMD
    lsr
    lsr
    lsr
    lsr
    beq @out
    ora #$10            ; constant volume; length counter remains active
    sta $400C
    lda music_noise_period,x
    sta $400E
    lda music_noise_length,x
    sta $400F
@out:
    rts

.else
.segment "FIXED"
audio_init:
audio_tick:
    rts
.endif
