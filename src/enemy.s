; Compact zombieman simulation. Movement is direct pursuit because this PoC
; has no BLOCKMAP collision/pathfinding yet; mutable subsectors keep rendering
; and floor selection coherent as actors cross BSP leaves.
.include "zeropage.inc"
.include "mmc5.inc"
.include "globals.inc"

.export update_enemies

.ifdef E1M1
.import find_subsector, move_blocked, move_leaf, move_radius
.import monster_thing_idx, MONSTER_COUNT

.segment "BSS"
enemy_slot:    .res 1
enemy_thing:   .res 1
enemy_dx:      .res 2
enemy_dy:      .res 2
enemy_damage:  .res 1
enemy_sight_x: .res 2
enemy_sight_y: .res 2
enemy_sight_n: .res 1

.segment "FIXED"

ENEMY_STEP = 16
ENEMY_MOVE_PERIOD = 8
ENEMY_ATTACK_PERIOD = 64
ENEMY_RANGE_HI = 8

update_enemies:
.ifdef FULL_E1M1
    lda #MAP_COMMON_BANK
    sta MMC5_PRG_A000
.endif
    ldx #0
@monster:
    cpx #<MONSTER_COUNT
    bcc :+
    rts
:
    stx enemy_slot
    ldy monster_thing_idx,x
    sty enemy_thing
    jsr enemy_is_active
    bne :+
    jmp @next
:
    ldy enemy_thing
    lda THING_HEALTH,y
    bne :+
    jmp @next
:

    ldx enemy_slot
    lda rf_t0
    sec
    sbc MONSTER_LAST_MOVE,x
    cmp #ENEMY_MOVE_PERIOD
    bcc @attack
    lda rf_t0
    sta MONSTER_LAST_MOVE,x
    jsr move_enemy

@attack:
    ldx enemy_slot
    lda rf_t0
    sec
    sbc MONSTER_LAST_ATTACK,x
    cmp #ENEMY_ATTACK_PERIOD
    bcs :+
    jmp @next
:
    jsr enemy_in_range
    bcc :+
    jmp @next
:
    jsr enemy_has_los
    bcc :+
    jmp @next
:
    ldx enemy_slot
    lda rf_t0
    sta MONSTER_LAST_ATTACK,x
    inc ENEMY_ATTACKS
    lda #1
    sta ENEMY_SOUND_PENDING
    jsr advance_enemy_rng
    and #1
    bne :+
    jmp @next                    ; 50% coarse accuracy
:
@damage_roll:
    jsr advance_enemy_rng
    and #7
    cmp #5
    bcs @damage_roll
    tax
    lda enemy_damage_table,x
    sta enemy_damage

    lda PL_ARMOR
    beq @apply_damage
    lda PL_ARMOR_TYPE
    cmp #2
    beq @blue_armor
    lda green_armor_save,x
    bne @have_save
@blue_armor:
    lda blue_armor_save,x
@have_save:
    cmp PL_ARMOR
    bcc :+
    lda PL_ARMOR
:   sta enemy_dx                ; saved damage
    lda PL_ARMOR
    sec
    sbc enemy_dx
    sta PL_ARMOR
    bne :+
    sta PL_ARMOR_TYPE
:   lda enemy_damage
    sec
    sbc enemy_dx
    sta enemy_damage

@apply_damage:
    lda PL_HEALTH
    cmp enemy_damage
    bcc @player_dies
    beq @player_dies
    sec
    sbc enemy_damage
    sta PL_HEALTH
    bne @damaged
@player_dies:
    lda #0
    sta PL_HEALTH
@damaged:
    lda #1
    sta HUD_DIRTY
    sta PLAYER_PAIN_SOUND_PENDING
    inc ENEMY_HITS

@next:
    ldx enemy_slot
    inx
    jmp @monster

; Z set when the current monster slot's thing is inactive.
enemy_is_active:
    tya
    and #7
    tax
    lda enemy_bits,x
    sta enemy_damage
    tya
    lsr
    lsr
    lsr
    tax
    lda THING_ACTIVE,x
    and enemy_damage
    rts

move_enemy:
    ; Move one converted world unit on each differing axis.
    lda MONSTER_X_HI,x
    cmp px+1
    bcc @x_inc
    bne @x_dec
    lda MONSTER_X_LO,x
    cmp px
    bcc @x_inc
    beq @move_y
@x_dec:
    lda MONSTER_X_LO,x
    sec
    sbc #ENEMY_STEP
    sta MONSTER_X_LO,x
    lda MONSTER_X_HI,x
    sbc #0
    sta MONSTER_X_HI,x
    jmp @move_y
@x_inc:
    lda MONSTER_X_LO,x
    clc
    adc #ENEMY_STEP
    sta MONSTER_X_LO,x
    lda MONSTER_X_HI,x
    adc #0
    sta MONSTER_X_HI,x

@move_y:
    lda MONSTER_Y_HI,x
    cmp py+1
    bcc @y_inc
    bne @y_dec
    lda MONSTER_Y_LO,x
    cmp py
    bcc @y_inc
    beq @locate
@y_dec:
    lda MONSTER_Y_LO,x
    sec
    sbc #ENEMY_STEP
    sta MONSTER_Y_LO,x
    lda MONSTER_Y_HI,x
    sbc #0
    sta MONSTER_Y_HI,x
    jmp @locate
@y_inc:
    lda MONSTER_Y_LO,x
    clc
    adc #ENEMY_STEP
    sta MONSTER_Y_LO,x
    lda MONSTER_Y_HI,x
    adc #0
    sta MONSTER_Y_HI,x

@locate:
    ; find_subsector operates on px/py; preserve the player camera around it.
    lda px
    pha
    lda px+1
    pha
    lda py
    pha
    lda py+1
    pha
    ldx enemy_slot
    lda MONSTER_X_LO,x
    sta px
    lda MONSTER_X_HI,x
    sta px+1
    lda MONSTER_Y_LO,x
    sta py
    lda MONSTER_Y_HI,x
    sta py+1
    jsr find_subsector
    txa
    ldx enemy_slot
    sta MONSTER_SS,x
    pla
    sta py+1
    pla
    sta py
    pla
    sta px+1
    pla
    sta px
.ifdef FULL_E1M1
    lda #MAP_COMMON_BANK
    sta MMC5_PRG_A000
.endif
    rts

; C clear when both axis distances are under 128 converted world units.
enemy_in_range:
    ldx enemy_slot
    lda MONSTER_X_LO,x
    sec
    sbc px
    sta enemy_dx
    lda MONSTER_X_HI,x
    sbc px+1
    sta enemy_dx+1
    bpl :+
    lda #0
    sec
    sbc enemy_dx
    sta enemy_dx
    lda #0
    sbc enemy_dx+1
    sta enemy_dx+1
:
    lda MONSTER_Y_LO,x
    sec
    sbc py
    sta enemy_dy
    lda MONSTER_Y_HI,x
    sbc py+1
    sta enemy_dy+1
    bpl :+
    lda #0
    sec
    sbc enemy_dy
    sta enemy_dy
    lda #0
    sbc enemy_dy+1
    sta enemy_dy+1
:
    lda enemy_dx+1
    cmp #ENEMY_RANGE_HI
    bcs @far
    lda enemy_dy+1
    cmp #ENEMY_RANGE_HI
    bcs @far
    clc
    rts
@far:
    sec
    rts

; Trace sixteen collision-tested substeps from the monster to the player.
; The attack range bounds each step to eight converted world units, so a
; one-sided wall or non-passable dynamic door cannot be skipped.
enemy_has_los:
    lda px
    sta enemy_sight_x
    lda px+1
    sta enemy_sight_x+1
    lda py
    sta enemy_sight_y
    lda py+1
    sta enemy_sight_y+1
    ldx enemy_slot
    lda enemy_sight_x
    sec
    sbc MONSTER_X_LO,x
    sta enemy_dx
    lda enemy_sight_x+1
    sbc MONSTER_X_HI,x
    sta enemy_dx+1
    lda enemy_sight_y
    sec
    sbc MONSTER_Y_LO,x
    sta enemy_dy
    lda enemy_sight_y+1
    sbc MONSTER_Y_HI,x
    sta enemy_dy+1
    .repeat 4
    lda enemy_dx+1
    cmp #$80
    ror enemy_dx+1
    ror enemy_dx
    lda enemy_dy+1
    cmp #$80
    ror enemy_dy+1
    ror enemy_dy
    .endrepeat
    lda MONSTER_X_LO,x
    sta px
    lda MONSTER_X_HI,x
    sta px+1
    lda MONSTER_Y_LO,x
    sta py
    lda MONSTER_Y_HI,x
    sta py+1
    lda #16
    sta enemy_sight_n
    lda #32             ; point-like ray tolerance, smaller than player radius
    sta move_radius
    lda #0
    sta move_radius+1
@sight_step:
    jsr find_subsector
    stx move_leaf
    lda px
    clc
    adc enemy_dx
    sta px
    lda px+1
    adc enemy_dx+1
    sta px+1
    lda py
    clc
    adc enemy_dy
    sta py
    lda py+1
    adc enemy_dy+1
    sta py+1
    jsr move_blocked
    bcs @sight_blocked
    dec enemy_sight_n
    bne @sight_step
    clc
    bcc @sight_restore
@sight_blocked:
    sec
@sight_restore:
    php
    lda enemy_sight_x
    sta px
    lda enemy_sight_x+1
    sta px+1
    lda enemy_sight_y
    sta py
    lda enemy_sight_y+1
    sta py+1
.ifdef FULL_E1M1
    lda #MAP_COMMON_BANK
    sta MMC5_PRG_A000
.endif
    plp
    rts

advance_enemy_rng:
    lda rng
    lsr
    bcc :+
    eor #$B8
:   sta rng
    rts

enemy_bits:
    .byte $01, $02, $04, $08, $10, $20, $40, $80
enemy_damage_table:
    .byte 3, 6, 9, 12, 15
green_armor_save:
    .byte 1, 2, 3, 4, 5
blue_armor_save:
    .byte 1, 3, 4, 6, 7

.else
.segment "FIXED"
update_enemies:
    rts
.endif
