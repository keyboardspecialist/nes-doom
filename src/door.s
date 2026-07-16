.include "zeropage.inc"
.include "mmc5.inc"
.include "globals.inc"

.ifdef E1M1

.import sec_floor, sec_ceil, door_sector, door_closed, door_open
.import door_use_x_lo, door_use_x_hi, door_use_y_lo, door_use_y_hi, door_use_id
.import MAP_SECTOR_COUNT : absolute
.import DOOR_COUNT : absolute
.import DOOR_USE_COUNT : absolute
.import LIFT_COUNT, EXIT_USE_COUNT : absolute
.import lift_sector, lift_high, lift_low
.import lift_x1_lo, lift_x1_hi, lift_y1_lo, lift_y1_hi
.import lift_x2_hi, lift_y2_hi
.import exit_use_x_lo, exit_use_x_hi, exit_use_y_lo, exit_use_y_hi
.import ss_first_lo, ss_first_hi, ss_count
.import find_subsector, load_seg, fetch_vertex, sub_cam, zdot, xdot

.export init_doors, update_doors, try_use, check_walk_special

DOOR_HOLD = 240
DOOR_USE_RANGE = 416        ; 26 converted world units (64 Doom units)
DOOR_USE_WIDTH = 512        ; accommodates aiming near a long door's endpoint

.segment "FIXED"

.macro DOOR_CALL target
    lda prg8000_sh
    pha
    lda #DOOR_CODE_BANK
    sta prg8000_sh
    sta MMC5_PRG_8000
    jsr target
    pla
    sta prg8000_sh
    sta MMC5_PRG_8000
    rts
.endmacro

init_doors:
    DOOR_CALL init_doors_impl

update_doors:
    DOOR_CALL update_doors_impl

try_use:
    DOOR_CALL try_use_impl

check_walk_special:
    DOOR_CALL check_walk_special_impl

.segment "DOORCODE"

init_doors_impl:
    ldx #<MAP_SECTOR_COUNT
    beq @clear
@copy_ceil:
    dex
    lda sec_floor,x
    sta SECTOR_FLOOR_RT,x
    lda sec_ceil,x
    sta SECTOR_CEIL_RT,x
    cpx #0
    bne @copy_ceil
@clear:
    ldx #7
    lda #0
@clear_door:
    sta DOOR_POS,x
    sta DOOR_STATE,x
    sta DOOR_PHASE,x
    sta DOOR_WAIT,x
    sta DOOR_PASSABLE,x
    dex
    bpl @clear_door
    lda frame_cnt
    sta DOOR_LAST_FRAME
    sta LIFT_LAST_FRAME
    lda #0
    sta LIFT_STATE
    sta LIFT_POS
    sta LIFT_PHASE
    sta LIFT_WAIT
    rts

update_doors_impl:
    lda frame_cnt
    sec
    sbc DOOR_LAST_FRAME
    bne :+
    jmp @done
:
    sta DOOR_ELAPSED
    lda frame_cnt
    sta DOOR_LAST_FRAME
    ldx #0
@door:
    cpx #<DOOR_COUNT
    bcc :+
    jmp @done
:
    lda DOOR_STATE,x
    bne :+
    jmp @next
:
    cmp #1
    beq @opening
    cmp #2
    beq @waiting

    ; Closing: one converted height unit per two video frames.
    jsr door_delta
    bne :+
    jmp @materialize
:
    sta rt_acc
    lda DOOR_POS,x
    cmp rt_acc
    bcc @closed
    beq @closed
    sec
    sbc rt_acc
    sta DOOR_POS,x
    jmp @materialize
@closed:
    lda #0
    sta DOOR_POS,x
    sta DOOR_STATE,x
    sta DOOR_PHASE,x
    sta DOOR_PASSABLE,x
    jmp @materialize

@opening:
    jsr door_delta
    bne :+
    jmp @materialize
:
    clc
    adc DOOR_POS,x
    sta rt_acc
    lda door_open,x
    sec
    sbc door_closed,x
    cmp rt_acc
    bcs :+
    sta rt_acc
:   lda rt_acc
    sta DOOR_POS,x
    lda door_open,x
    sec
    sbc door_closed,x
    cmp DOOR_POS,x
    beq :+
    jmp @materialize
:
    lda #2
    sta DOOR_STATE,x
    lda #DOOR_HOLD
    sta DOOR_WAIT,x
    lda #0                  ; publish passability on the following compose pass
    sta DOOR_PASSABLE,x
    jmp @materialize

@waiting:
    lda DOOR_PASSABLE,x
    bne @count_wait
    lda #1
    sta DOOR_PASSABLE,x
    jmp @materialize
@count_wait:
    lda DOOR_WAIT,x
    cmp DOOR_ELAPSED
    bcc @wait_done
    beq @wait_done
    sec
    sbc DOOR_ELAPSED
    sta DOOR_WAIT,x
    beq @wait_done
    jmp @materialize
@wait_done:
    jsr door_player_near
    bcs @postpone_close
    ldy door_sector,x       ; never close on the player inside the door sector
    cpy cam_sec
    bne @start_close
@postpone_close:
    lda #30
    sta DOOR_WAIT,x
    jmp @materialize
@start_close:
    lda #3
    sta DOOR_STATE,x
    lda #1
    sta DOOR_SOUND_PENDING
    lda #0
    sta DOOR_PHASE,x
    sta DOOR_PASSABLE,x     ; closing becomes solid before its first frame

@materialize:
    ldy door_sector,x
    lda door_closed,x
    clc
    adc DOOR_POS,x
    sta SECTOR_CEIL_RT,y
@next:
    inx
    jmp @door
@done:
    jsr update_lift_impl
    rts

update_lift_impl:
    lda #<LIFT_COUNT
    bne :+
    rts
:
    lda LIFT_STATE
    bne :+
    rts
:
    cmp #2
    beq @lift_waiting
    lda LIFT_PHASE
    clc
    adc DOOR_ELAPSED
    sta rt_acc
    and #3
    sta LIFT_PHASE
    lda rt_acc
    lsr
    lsr
    bne :+
    jmp @lift_materialize
:
    sta rt_acc
    lda LIFT_STATE
    cmp #1
    bne @lift_raising
    lda lift_high
    sec
    sbc lift_low
    sta rt_dx
    lda LIFT_POS
    clc
    adc rt_acc
    cmp rt_dx
    bcc :+
    lda rt_dx
    sta LIFT_POS
    lda #2
    sta LIFT_STATE
    lda #180
    sta LIFT_WAIT
    ldx #<DOOR_COUNT
    lda #1
    sta DOOR_PASSABLE,x
    jmp @lift_materialize
:   sta LIFT_POS
    jmp @lift_materialize
@lift_raising:
    lda LIFT_POS
    cmp rt_acc
    bcc @lift_top
    beq @lift_top
    sec
    sbc rt_acc
    sta LIFT_POS
    jmp @lift_materialize
@lift_top:
    lda #0
    sta LIFT_POS
    sta LIFT_STATE
    sta LIFT_PHASE
    ldx #<DOOR_COUNT
    sta DOOR_PASSABLE,x
    jmp @lift_materialize
@lift_waiting:
    lda LIFT_WAIT
    cmp DOOR_ELAPSED
    bcc @lift_start_raise
    beq @lift_start_raise
    sec
    sbc DOOR_ELAPSED
    sta LIFT_WAIT
    jmp @lift_materialize
@lift_start_raise:
    lda #3
    sta LIFT_STATE
    lda #0
    sta LIFT_PHASE
    ldx #<DOOR_COUNT
    sta DOOR_PASSABLE,x
@lift_materialize:
    ldx lift_sector
    lda lift_high
    sec
    sbc LIFT_POS
    sta SECTOR_FLOOR_RT,x
    rts

check_walk_special_impl:
    lda #<LIFT_COUNT
    bne :+
    rts
:
    lda LIFT_STATE
    beq :+
    rts
:
    lda px
    cmp PLAYER_PREV_X
    bne @walk_bounds
    lda px+1
    cmp PLAYER_PREV_X+1
    bne @walk_bounds
    lda py
    cmp PLAYER_PREV_Y
    bne @walk_bounds
    lda py+1
    cmp PLAYER_PREV_Y+1
    beq @walk_done
@walk_bounds:
    lda px+1
    cmp lift_x1_hi
    bcc @walk_done
    cmp lift_x2_hi
    bcc @check_walk_y
    beq @check_walk_y
    bcs @walk_done
@check_walk_y:
    lda py+1
    cmp lift_y1_hi
    bcc @walk_done
    cmp lift_y2_hi
    bcc @walk_side
    beq @walk_side
    bcs @walk_done
@walk_side:
    jsr lift_line_side
    sta DOOR_BEST_LO
    lda px
    pha
    lda px+1
    pha
    lda py
    pha
    lda py+1
    pha
    lda PLAYER_PREV_X
    sta px
    lda PLAYER_PREV_X+1
    sta px+1
    lda PLAYER_PREV_Y
    sta py
    lda PLAYER_PREV_Y+1
    sta py+1
    jsr lift_line_side
    sta DOOR_BEST_HI
    pla
    sta py+1
    pla
    sta py
    pla
    sta px+1
    pla
    sta px
    lda DOOR_BEST_LO
    eor DOOR_BEST_HI
    bpl @walk_done
    lda #1
    sta LIFT_STATE
    lda #0
    sta LIFT_PHASE
@walk_done:
    rts

; Approximate the trigger diagonal with its 4:7 high-resolution slope.
; Return the signed high byte of (x-x1)*4 - (y-y1)*7.
lift_line_side:
    lda px
    sec
    sbc lift_x1_lo
    sta rt_dx
    lda px+1
    sbc lift_x1_hi
    sta rt_dx+1
    asl rt_dx
    rol rt_dx+1
    asl rt_dx
    rol rt_dx+1
    lda rt_dx
    sta rt_acc
    lda rt_dx+1
    sta rt_acc+1
    lda py
    sec
    sbc lift_y1_lo
    sta rt_dy
    sta mul_a
    lda py+1
    sbc lift_y1_hi
    sta rt_dy+1
    sta mul_a+1
    asl rt_dy
    rol rt_dy+1
    asl rt_dy
    rol rt_dy+1
    asl rt_dy
    rol rt_dy+1
    lda rt_dy
    sec
    sbc mul_a
    sta rt_dy
    lda rt_dy+1
    sbc mul_a+1
    sta rt_dy+1
    lda rt_acc
    sec
    sbc rt_dy
    lda rt_acc+1
    sbc rt_dy+1
    rts

; Return floor((phase + elapsed) / 2) in A and retain the half-unit phase.
door_delta:
    lda DOOR_PHASE,x
    clc
    adc DOOR_ELAPSED
    pha
    and #1
    sta DOOR_PHASE,x
    pla
    ror
    rts

; C set when the player remains within doorway clearance of door X.
door_player_near:
    stx DOOR_BEST_ID
    lda #0
    sta DOOR_USE_INDEX
@check:
    ldx DOOR_USE_INDEX
    cpx #<DOOR_USE_COUNT
    bcs @far
    lda door_use_id,x
    cmp DOOR_BEST_ID
    bne @next
    lda door_use_x_lo,x
    sec
    sbc px
    sta rt_dx
    lda door_use_x_hi,x
    sbc px+1
    sta rt_dx+1
    bpl :+
    sec
    lda #0
    sbc rt_dx
    sta rt_dx
    lda #0
    sbc rt_dx+1
    sta rt_dx+1
:   lda rt_dx+1
    cmp #>DOOR_USE_RANGE
    bcc @check_y
    bne @next
    lda rt_dx
    cmp #<(DOOR_USE_RANGE+1)
    bcs @next
@check_y:
    ldx DOOR_USE_INDEX
    lda door_use_y_lo,x
    sec
    sbc py
    sta rt_dy
    lda door_use_y_hi,x
    sbc py+1
    sta rt_dy+1
    bpl :+
    sec
    lda #0
    sbc rt_dy
    sta rt_dy
    lda #0
    sbc rt_dy+1
    sta rt_dy+1
:   lda rt_dy+1
    cmp #>DOOR_USE_RANGE
    bcc @near
    bne @next
    lda rt_dy
    cmp #<(DOOR_USE_RANGE+1)
    bcc @near
@next:
    inc DOOR_USE_INDEX
    bne @check
@far:
    ldx DOOR_BEST_ID
    clc
    rts
@near:
    ldx DOOR_BEST_ID
    sec
    rts

try_use_impl:
    lda joy_render
    and #$02
    bne :+
    rts
:   lda #$FF
    sta DOOR_BEST_ID
    sta DOOR_BEST_LO
    sta DOOR_BEST_HI
    jsr find_subsector
.ifdef FULL_E1M1
    lda #MAP_COMMON_BANK
    sta MMC5_PRG_A000
.endif
    lda ss_first_lo,x
    sta ss_idx
    lda ss_first_hi,x
    sta ss_idx_hi
    lda ss_count,x
    sta ss_n
@candidate:
    lda ss_n
    bne :+
    jmp @activate
:
    jsr load_seg
    ldy #6
    lda (wall_ptr),y
    and #$70
    bne :+
    jmp @next_use
:
    .repeat 4
    lsr
    .endrepeat
    sec
    sbc #1
    sta seg_texoff

    ; Midpoint of the actual seg in the current leaf keeps Use occlusion-local.
    ldy #0
    jsr fetch_vertex
    lda wx
    sta dx1
    lda wx+1
    sta dx1+1
    lda wy
    sta dy1
    lda wy+1
    sta dy1+1
    ldy #2
    jsr fetch_vertex
    lda wx
    sec
    sbc dx1
    sta rt_dx
    lda wx+1
    sbc dx1+1
    sta rt_dx+1
    cmp #$80
    ror rt_dx+1
    ror rt_dx
    lda dx1
    clc
    adc rt_dx
    sta wx
    lda dx1+1
    adc rt_dx+1
    sta wx+1
    lda wy
    sec
    sbc dy1
    sta rt_dy
    lda wy+1
    sbc dy1+1
    sta rt_dy+1
    cmp #$80
    ror rt_dy+1
    ror rt_dy
    lda dy1
    clc
    adc rt_dy
    sta wy
    lda dy1+1
    adc rt_dy+1
    sta wy+1
    jsr sub_cam
    jsr zdot
    lda ttz+1
    bmi @next_use
    ora ttz
    beq @next_use
    lda ttz+1
    cmp #>DOOR_USE_RANGE
    bcc @facing
    bne @next_use
    lda ttz
    cmp #<(DOOR_USE_RANGE+1)
    bcs @next_use
@facing:
    jsr xdot
    lda ttx+1
    bpl @abs_ready
    sec
    lda #0
    sbc ttx
    sta ttx
    lda #0
    sbc ttx+1
    sta ttx+1
@abs_ready:
    lda ttx+1
    cmp #>DOOR_USE_WIDTH
    bcc @nearer
    bne @next_use
    lda ttx
    cmp #<(DOOR_USE_WIDTH+1)
    bcs @next_use
@nearer:
    lda ttz+1
    cmp DOOR_BEST_HI
    bcc @select
    bne @next_use
    lda ttz
    cmp DOOR_BEST_LO
    bcs @next_use
@select:
    lda ttz
    sta DOOR_BEST_LO
    lda ttz+1
    sta DOOR_BEST_HI
    lda seg_texoff
    sta DOOR_BEST_ID
@next_use:
    inc ss_idx
    bne :+
    inc ss_idx_hi
:   dec ss_n
    jmp @candidate

@activate:
    ldx DOOR_BEST_ID
    cpx #$FF
    bne :+
    jmp try_exit_impl
:   lda DOOR_STATE,x
    cmp #2
    bne :+
    lda #DOOR_HOLD
    sta DOOR_WAIT,x
    rts
:   cmp #1
    beq @used
    lda #1
    sta DOOR_STATE,x
    sta DOOR_SOUND_PENDING
    lda #0
    sta DOOR_PHASE,x
    sta DOOR_PASSABLE,x
@used:
    rts

try_exit_impl:
    lda #<EXIT_USE_COUNT
    bne :+
    rts
:
    lda exit_use_x_lo
    sta wx
    lda exit_use_x_hi
    sta wx+1
    lda exit_use_y_lo
    sta wy
    lda exit_use_y_hi
    sta wy+1
    jsr sub_cam
    jsr zdot
    lda ttz+1
    bmi @exit_done
    cmp #>DOOR_USE_RANGE
    bcc @exit_facing
    bne @exit_done
    lda ttz
    cmp #<(DOOR_USE_RANGE+1)
    bcs @exit_done
@exit_facing:
    jsr xdot
    lda ttx+1
    bpl :+
    sec
    lda #0
    sbc ttx
    sta ttx
    lda #0
    sbc ttx+1
    sta ttx+1
:
    lda ttx+1
    cmp #>DOOR_USE_WIDTH
    bcc @complete
    bne @exit_done
    lda ttx
    cmp #<(DOOR_USE_WIDTH+1)
    bcs @exit_done
@complete:
    lda #1
    sta LEVEL_COMPLETE
    sta EXIT_SOUND_PENDING
@exit_done:
    rts

.endif
