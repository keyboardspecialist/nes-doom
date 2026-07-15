; M5 renderer: BSP-driven seg rasterizer with variable floor/ceiling heights,
; per-column occlusion clips, two-sided portals (upper/lower walls), per-sector
; light + distance diminishing.
;
; Per seg: transform endpoints (4 mul16s each), near-clip via reciprocal
; fraction, project (col = 16 + hi16(tx*rzh)>>3). Heights use Doom's trick:
; screen row offset = (h * rzh) >> 15 is linear in screen x, so multiply once
; per seg endpoint and add a step per column — no per-column multiplies.
;
; Screen rows: horizon at row 10; rowtop = 10 - (hceil*rzh>>15),
; rowbot = 10 + (hfloor*rzh>>15); heights precomputed relative to eye (48u).
;
; Known simplifications (for the feasibility doc):
;   - affine u interpolation (texture swim at oblique angles)
;   - spans > 255 columns use a clamped interpolation step
;   - walls taller than the view: slice class capped at 20, offset clamped
;     to the last texture row (stretch artifact when very close)
.include "zeropage.inc"
.include "mmc5.inc"
.include "globals.inc"

.import mul16u, mul16s, mul16s9, mul16s8u
.import mul8u16u, mul8s16u, mul8s16s, mul16s16u
.import atan2_hi, render_bsp, find_sector, find_subsector, load_seg
.import sin_lo, sin_hi, recipf_lo, recipf_hi
.import recip_col_lo, recip_col_hi, light2_tbl, angcol_tbl
.import slice_tile, slice_bank, tex_base_lo, tex_base_hi
.import tex_max_class, tex_vperiod
.import vhalf_ptr_lo, vhalf_ptr_hi
.import map_verts, sec_floor, sec_ceil, sec_light
.import ss_first_lo, ss_first_hi, ss_count
.import ceil_clip, floor_clip
.import PLAYER_PX, PLAYER_PY, PLAYER_ANG, EYE_REL
.import PX_MIN_H, PX_MAX_H, PY_MIN_H, PY_MAX_H
.import REJECT_ROWB, reject_tbl
.ifdef E1M1
.import ss_sector, ss_thing_first, ss_thing_count, thing_x_lo, thing_x_hi
.import thing_y_lo, thing_y_hi, thing_kind
.import MAP_THING_COUNT
.import weapon_oam, weapon_frame_first, weapon_frame_count, weapon_scan_count
.import WEAPON_FRAME_COUNT, WEAPON_SLOT_CAP
.import world_kind_meta_base, world_kind_frame_mask, world_kind_world_h
.import world_meta_first, world_meta_count
.import world_sprite_dx, world_sprite_dy, world_sprite_tile, world_sprite_attr
.import barrel_exp_meta_first, barrel_exp_meta_count
.import barrel_exp_dx, barrel_exp_dy, barrel_exp_tile, barrel_exp_attr
.import monster_thing_idx, MONSTER_COUNT
.import update_enemies
.import init_doors, update_doors, try_use
.endif
.export render_frame, init_camera, do_seg, fetch_vertex, sub_cam, zdot, xdot
.ifdef E1M1
.export draw_subsector_things, init_oam_set
.endif

.segment "BSS"
vang:    .res 256           ; per-vertex view angle (BAM hi-byte)
vstamp:  .res 256           ; generation when this vertex was computed
vflags:  .res 256           ; bit 7: too close for a reliable angle
.ifdef FULL_E1M1
hvang:       .res 8          ; direct-mapped cache for vertex indices >= 256
hvindex_lo:  .res 8
hvindex_hi:  .res 8
hvstamp:     .res 8
hvflags:     .res 8          ; bit 7: cached too-close result
.endif
move_dx:    .res 2
move_dy:    .res 2
move_dx_total: .res 2
move_dy_total: .res 2
move_old:   .res 2
move_x1:    .res 2
move_y1:    .res 2
move_cross: .res 4
move_leaf:  .res 1
move_pass:  .res 1
.ifdef E1M1
spr_scan_count:  .res 160    ; exact software enforcement of the PPU limit
spr_floor:       .res 1
spr_things_left: .res 1
spr_cells_left:  .res 1
spr_exploding:   .res 1
spr_exp_emitted: .res 1
spr_monster:      .res 1
spr_current_ss:   .res 1
spr_frame:        .res 1
.endif

SPRITE_NEAR = 256           ; sprites retain the 16-unit projection cutoff
WALL_NEAR = 64              ; walls clip at 4 units; gameplay keeps us farther
.ifdef E1M1
PLAYER_RADIUS = 103         ; 6.4375 units (16 Doom units scaled by 0.4)
.else
PLAYER_RADIUS = 256         ; 16 world units in the synthetic map
.endif
TURN    = 512               ; BAM per pass (~2.8 deg)
CEIL_NT  = 4                ; blank tile -> the backdrop IS the ceiling color
CEIL_EX  = FLAT_BANK | $80  ; palette bits irrelevant for a blank tile
FLOOR_NT = 2
FLOOR_EX = FLAT_BANK | $80  ; cool/gray ramp; dark bit added below fl_thr
EDGE_TOP_BASE = 4           ; tiles 5-11: k wall rows below ceiling color
EDGE_BOT_BASE = 11          ; tiles 12-18: k wall rows above floor color
PORTAL_TOP_BASE = 19        ; 64 tiles: frontFrac*8 + backFrac
PORTAL_BOT_BASE = 83        ; 64 tiles: portal / wall strip / floor
PORTAL_TOP_WRAP = 147       ; subpixel strip in fraction bucket 7
PORTAL_BOT_WRAP = 148

.segment "CODE"

init_camera:
    lda #<PLAYER_PX
    sta px
    lda #>PLAYER_PX
    sta px+1
    lda #<PLAYER_PY
    sta py
    lda #>PLAYER_PY
    sta py+1
    lda #<PLAYER_ANG
    sta pang
    lda #>PLAYER_ANG
    sta pang+1
.ifdef E1M1
    jsr init_doors
.endif
    rts

render_frame:
.ifdef FULL_E1M1
    lda #MAP_COMMON_BANK
    sta MMC5_PRG_A000
.endif
    lda frame_cnt
    sta rf_t0
    lda #0
    sta cols_drawn
    sta segs_drawn
    sta nodes_visited
    jsr consume_input
.ifdef E1M1
    jsr update_doors
.endif
    jsr update_cam
.ifdef E1M1
    jsr try_use
.endif
.ifdef E1M1
    ; NMI counts shots independently of the slower renderer. One BSP pass
    ; finds the nearest visible barrel for the entire wrapped delta.
    lda SHOT_COUNT
    tax
    sec
    sbc SHOT_SEEN
    sta SHOT_PENDING
    stx SHOT_SEEN
    beq :+
    lda #$FF
    sta SHOT_TARGET
    sta SHOT_BEST_LO
    lda #$7F
    sta SHOT_BEST_HI
:
    jsr expire_explosions
    jsr collect_pickups
    jsr update_enemies
.endif
    jsr find_sector     ; -> cam_sec; eye follows the camera's sector floor
    ldx cam_sec
    lda sec_floor,x
    clc
    adc #<EYE_REL
    sta eye_h
.ifdef E1M1
    ; Attach the camera sector to this compose buffer.  The pusher publishes
    ; it only after the buffer's final column is visible.
    lda front_buf
    eor #1
    tax
    lda cam_sec
    sta BUFA_PAL_SEC,x
.endif
    ; rj_ptr = reject_tbl + cam_sec * REJECT_ROWB. Keep both product bytes so
    ; maps whose REJECT rows cross a page retain the same behavior as E1M1.
    lda cam_sec
    sta MMC5_MULT_A
    lda #<REJECT_ROWB
    sta MMC5_MULT_B
    lda MMC5_MULT_A
    clc
    adc #<reject_tbl
    sta rj_ptr
    lda MMC5_MULT_B
    adc #>reject_tbl
    sta rj_ptr+1
    lda front_buf
    eor #1
    sta rf_back
    asl
    asl
    asl
    asl
    asl
    sta rf_backoff
.ifdef E1M1
    ldx rf_back
    lda #0
    sta BUFA_EXPLOSION_SOUND,x
    jsr sprite_frame_begin
.endif
    ; Invalidate the angle cache with one generation increment.  On the rare
    ; wrap, clear stamps so old generation 1 entries cannot become valid.
    inc vang_gen
    bne @cache_ready
    ldx #0
    lda #0
@clear_vstamp:
    sta vstamp,x
    inx
    bne @clear_vstamp
.ifdef FULL_E1M1
    ldx #7
@clear_hvstamp:
    sta hvstamp,x
    dex
    bpl @clear_hvstamp
.endif
    inc vang_gen
@cache_ready:
    jsr render_bsp
.ifdef E1M1
    jsr resolve_pending_shots
.endif
    lda frame_cnt
    sec
    sbc rf_t0
    sta pass_frames
    rts

; NMI owns joy_latched. Briefly disabling NMI around the exchange prevents a
; direction sampled at the boundary from being cleared before the next pass.
consume_input:
    lda ppu2000_sh
    and #$7F
    sta $2000
    lda joy_latched
    sta joy_render
    lda #0
    sta joy_latched
    lda ppu2000_sh
    sta $2000
    rts

update_cam:
    lda joy_render
    and #$40            ; Left: rotate CCW
    beq :+
    lda pang
    clc
    adc #<TURN
    sta pang
    lda pang+1
    adc #>TURN
    sta pang+1
:   lda joy_render
    and #$80            ; Right: rotate CW
    beq :+
    lda pang
    sec
    sbc #<TURN
    sta pang
    lda pang+1
    sbc #>TURN
    sta pang+1
:   ldy pang+1
    lda sin_lo,y
    sta vsin
    lda sin_hi,y
    sta vsin+1
    tya
    clc
    adc #64
    tay
    lda sin_lo,y
    sta vcos
    lda sin_hi,y
    sta vcos+1
    lda joy_render
    and #$10            ; Up: forward (step = view dir / 2 = 8 units)
    beq :+
    jsr step_forward
:   lda joy_render
    and #$20            ; Down: back
    beq :+
    jsr step_back
:   ; loose world clamp, hi-byte compares against map-exported bounds
    ; (all map coordinates are positive by converter convention)
    lda px+1
    cmp #<PX_MIN_H
    bcs :+
    jsr set_px_min
:   lda px+1
    cmp #<PX_MAX_H
    bcc :+
    jsr set_px_max
:   lda py+1
    cmp #<PY_MIN_H
    bcs :+
    jsr set_py_min
:   lda py+1
    cmp #<PY_MAX_H
    bcc :+
    jsr set_py_max
:   rts

set_px_min:
    lda #<PX_MIN_H
    sta px+1
    lda #0
    sta px
    rts
set_px_max:
    lda #<PX_MAX_H
    sta px+1
    lda #0
    sta px
    rts
set_py_min:
    lda #<PY_MIN_H
    sta py+1
    lda #0
    sta py
    rts
set_py_max:
    lda #<PY_MAX_H
    sta py+1
    lda #0
    sta py
    rts

.segment "FIXED"

step_forward:
    jsr half_view
    jmp move_two_steps

step_back:
    jsr half_view
    sec
    lda #0
    sbc rt_dx
    sta rt_dx
    lda #0
    sbc rt_dx+1
    sta rt_dx+1
    sec
    lda #0
    sbc rt_dy
    sta rt_dy
    lda #0
    sbc rt_dy+1
    sta rt_dy+1
move_two_steps:
    lda rt_dx
    sta move_dx_total
    lda rt_dx+1
    sta move_dx_total+1
    lda rt_dy
    sta move_dy_total
    lda rt_dy+1
    sta move_dy_total+1
    lda rt_dx+1
    cmp #$80
    ror rt_dx+1
    ror rt_dx
    lda rt_dy+1
    cmp #$80
    ror rt_dy+1
    ror rt_dy
    lda rt_dx
    sta move_dx
    lda rt_dx+1
    sta move_dx+1
    lda rt_dy
    sta move_dy
    lda rt_dy+1
    sta move_dy+1
    jsr try_move_axes
    lda move_dx_total
    sec
    sbc move_dx
    sta move_dx
    lda move_dx_total+1
    sbc move_dx+1
    sta move_dx+1
    lda move_dy_total
    sec
    sbc move_dy
    sta move_dy
    lda move_dy_total+1
    sbc move_dy+1
    sta move_dy+1
    jsr try_move_axes
    rts

try_move_axes:
    lda move_dx
    ora move_dx+1
    beq @try_y
    jsr find_subsector
    stx move_leaf
    lda px
    sta move_old
    lda px+1
    sta move_old+1
    lda px
    clc
    adc move_dx
    sta px
    lda px+1
    adc move_dx+1
    sta px+1
    jsr move_blocked
    bcc @try_y
    lda move_old
    sta px
    lda move_old+1
    sta px+1
@try_y:
    lda move_dy
    ora move_dy+1
    beq @done
    jsr find_subsector
    stx move_leaf
    lda py
    sta move_old
    lda py+1
    sta move_old+1
    lda py
    clc
    adc move_dy
    sta py
    lda py+1
    adc move_dy+1
    sta py+1
    jsr move_blocked
    bcc @done
    lda move_old
    sta py
    lda move_old+1
    sta py+1
@done:
    rts

; Candidate px/py is blocked when its circle overlaps a blocking boundary seg
; of the old convex subsector.  C set = blocked.
move_blocked:
    lda #0
    sta move_pass
@scan_leaf:
.ifdef FULL_E1M1
    lda #MAP_COMMON_BANK
    sta MMC5_PRG_A000
.endif
    ldx move_leaf
    lda ss_first_lo,x
    sta ss_idx
    lda ss_first_hi,x
    sta ss_idx_hi
    lda ss_count,x
    sta ss_n
@line:
    jsr load_seg
    ldy #6
    lda (wall_ptr),y
    bpl @next
.ifdef E1M1
    sta seg_texoff
    and #$70
    beq @static_blocker
    .repeat 4
    lsr
    .endrepeat
    tax
    dex
    lda DOOR_PASSABLE,x
    bne @next
@static_blocker:
.endif
    jsr collision_seg
    bcs @blocked
@next:
    inc ss_idx
    bne :+
    inc ss_idx_hi
:   dec ss_n
    bne @line
    lda move_pass
    bne @clear
    jsr find_subsector      ; candidate leaf can expose adjacent blockers
    cpx move_leaf
    beq @clear
    stx move_leaf
    inc move_pass
    jmp @scan_leaf
@clear:
    clc
    rts
@blocked:
    sec
    rts

collision_seg:
    ldy #0
    jsr fetch_vertex
    lda wx
    sta move_x1
    lda wx+1
    sta move_x1+1
    lda wy
    sta move_y1
    lda wy+1
    sta move_y1+1
    ldy #2
    jsr fetch_vertex

    ; Reject lines whose radius-expanded segment box does not contain P.
    lda px
    sta mul_a
    lda px+1
    sta mul_a+1
    lda move_x1
    sta mul_b
    lda move_x1+1
    sta mul_b+1
    lda wx
    sta rt_acc
    lda wx+1
    sta rt_acc+1
    jsr axis_near
    bcs :+
    clc
    rts
:
    lda py
    sta mul_a
    lda py+1
    sta mul_a+1
    lda move_y1
    sta mul_b
    lda move_y1+1
    sta mul_b+1
    lda wy
    sta rt_acc
    lda wy+1
    sta rt_acc+1
    jsr axis_near
    bcs :+
    clc
    rts
:

    ; seg delta in dx1/dy1, then cross = segdy*pointdx - segdx*pointdy.
    lda wx
    sec
    sbc move_x1
    sta dx1
    lda wx+1
    sbc move_x1+1
    sta dx1+1
    lda wy
    sec
    sbc move_y1
    sta dy1
    lda wy+1
    sbc move_y1+1
    sta dy1+1

    lda dy1
    sta mul_a
    lda dy1+1
    sta mul_a+1
    lda px
    sec
    sbc move_x1
    sta mul_b
    lda px+1
    sbc move_x1+1
    sta mul_b+1
    jsr mul16s
    ldx #3
@save_cross:
    lda mul_r,x
    sta move_cross,x
    dex
    bpl @save_cross
    lda dx1
    sta mul_a
    lda dx1+1
    sta mul_a+1
    lda py
    sec
    sbc move_y1
    sta mul_b
    lda py+1
    sbc move_y1+1
    sta mul_b+1
    jsr mul16s
    lda move_cross
    sec
    sbc mul_r
    sta move_cross
    lda move_cross+1
    sbc mul_r+1
    sta move_cross+1
    lda move_cross+2
    sbc mul_r+2
    sta move_cross+2
    lda move_cross+3
    sbc mul_r+3
    sta move_cross+3
    bmi :+
    sec                  ; on/back of the directed boundary
    rts
:

    ; Magnitude of the negative cross product.
    sec
    lda #0
    sbc move_cross
    sta move_cross
    lda #0
    sbc move_cross+1
    sta move_cross+1
    lda #0
    sbc move_cross+2
    sta move_cross+2
    lda #0
    sbc move_cross+3
    sta move_cross+3

    ; max + min/2 approximates Euclidean length within about 12%, avoiding
    ; the sqrt(2) over-expansion of an L1 threshold on diagonal walls.
    lda dx1
    sta rt_acc
    lda dx1+1
    sta rt_acc+1
    bpl :+
    jsr neg_rt_acc
:   lda dy1
    sta tptr
    lda dy1+1
    sta tptr+1
    bpl :+
    jsr neg_tptr
:   lda rt_acc+1
    cmp tptr+1
    bcc @swap_lengths
    bne @length_ordered
    lda rt_acc
    cmp tptr
    bcs @length_ordered
@swap_lengths:
    lda rt_acc
    pha
    lda tptr
    sta rt_acc
    pla
    sta tptr
    lda rt_acc+1
    pha
    lda tptr+1
    sta rt_acc+1
    pla
    sta tptr+1
@length_ordered:
    lsr tptr+1
    ror tptr
    lda rt_acc
    clc
    adc tptr
    sta mul_a
    lda rt_acc+1
    adc tptr+1
    sta mul_a+1
    lda #<PLAYER_RADIUS
    sta mul_b
    lda #>PLAYER_RADIUS
    sta mul_b+1
    jsr mul16u
    ldx #3
@cmp_threshold:
    lda move_cross,x
    cmp mul_r,x
    bcc @hit
    bne @clear
    dex
    bpl @cmp_threshold
@clear:
    clc
    rts
@hit:
    sec
    rts

; Candidate mul_a, endpoints mul_b/rt_acc. C set when inside expanded range.
axis_near:
    lda mul_b+1
    cmp rt_acc+1
    bcc @ordered
    bne @swap
    lda mul_b
    cmp rt_acc
    bcc @ordered
@swap:
    lda mul_b
    pha
    lda rt_acc
    sta mul_b
    pla
    sta rt_acc
    lda mul_b+1
    pha
    lda rt_acc+1
    sta mul_b+1
    pla
    sta rt_acc+1
@ordered:
    lda mul_b
    sec
    sbc #<PLAYER_RADIUS
    sta tptr
    lda mul_b+1
    sbc #>PLAYER_RADIUS
    sta tptr+1
    bcs :+
    lda #0
    sta tptr
    sta tptr+1
:   lda mul_a+1
    cmp tptr+1
    bcc @outside
    bne :+
    lda mul_a
    cmp tptr
    bcc @outside
:   lda rt_acc
    clc
    adc #<PLAYER_RADIUS
    sta tptr
    lda rt_acc+1
    adc #>PLAYER_RADIUS
    sta tptr+1
    bcc :+
    lda #$FF
    sta tptr
    sta tptr+1
:   lda mul_a+1
    cmp tptr+1
    bcc @inside
    bne @outside
    lda mul_a
    cmp tptr
    bcc @inside
    beq @inside
@outside:
    clc
    rts
@inside:
    sec
    rts

neg_rt_acc:
    sec
    lda #0
    sbc rt_acc
    sta rt_acc
    lda #0
    sbc rt_acc+1
    sta rt_acc+1
    rts

neg_tptr:
    sec
    lda #0
    sbc tptr
    sta tptr
    lda #0
    sbc tptr+1
    sta tptr+1
    rts

.segment "CODE"

half_view:                  ; rt_dx/rt_dy = (vcos, vsin) >> 1 signed
    lda vcos
    sta rt_dx
    lda vcos+1
    sta rt_dx+1
    cmp #$80
    ror rt_dx+1
    ror rt_dx
    lda vsin
    sta rt_dy
    lda vsin+1
    sta rt_dy+1
    cmp #$80
    ror rt_dy+1
    ror rt_dy
    rts

; camera-relative deltas of (wx,wy) -> rt_dx/rt_dy
sub_cam:
    lda wx
    sec
    sbc px
    sta rt_dx
    lda wx+1
    sbc px+1
    sta rt_dx+1
    lda wy
    sec
    sbc py
    sta rt_dy
    lda wy+1
    sbc py+1
    sta rt_dy+1
    rts

; ttz = (rt_dx*vcos + rt_dy*vsin) >> 8   (depth only — cheap early rejects)
zdot:
    lda rt_dx
    sta mul_a
    lda rt_dx+1
    sta mul_a+1
    lda vcos
    sta mul_b
    lda vcos+1
    sta mul_b+1
    jsr mul16s9
    lda mul_r+1
    sta rt_acc
    lda mul_r+2
    sta rt_acc+1
    lda rt_dy
    sta mul_a
    lda rt_dy+1
    sta mul_a+1
    lda vsin
    sta mul_b
    lda vsin+1
    sta mul_b+1
    jsr mul16s9
    lda rt_acc
    clc
    adc mul_r+1
    sta ttz
    lda rt_acc+1
    adc mul_r+2
    sta ttz+1
    rts

; ttx = (rt_dx*vsin - rt_dy*vcos) >> 8
xdot:
    lda rt_dx
    sta mul_a
    lda rt_dx+1
    sta mul_a+1
    lda vsin
    sta mul_b
    lda vsin+1
    sta mul_b+1
    jsr mul16s9
    lda mul_r+1
    sta rt_acc
    lda mul_r+2
    sta rt_acc+1
    lda rt_dy
    sta mul_a
    lda rt_dy+1
    sta mul_a+1
    lda vcos
    sta mul_b
    lda vcos+1
    sta mul_b+1
    jsr mul16s9
    lda rt_acc
    sec
    sbc mul_r+1
    sta ttx
    lda rt_acc+1
    sbc mul_r+2
    sta ttx+1
    rts

; rzh = 524288/z.  The table covers 0..1023 world units; for 1024..2047,
; look up z/2 and halve the result instead of freezing distant perspective.
rzh_lookup:
    lda ttz
    sta tptr
    lda ttz+1
    sta tptr+1
    .repeat 4
    lsr tptr+1
    ror tptr
    .endrepeat
    lda #0
    sta vtmp
@rzh_norm:
    lda tptr+1
    cmp #4
    bcc :+
    lsr tptr+1
    ror tptr
    inc vtmp
    bne @rzh_norm
:   lda tptr
    clc
    adc #<recipf_lo
    sta tptr
    lda tptr+1
    adc #>recipf_lo
    sta tptr+1
    ldy #0
    lda (tptr),y
    pha
    lda tptr+1
    clc
    adc #4
    sta tptr+1
    lda (tptr),y
    tax
    pla
    ldy vtmp
    beq :+
@rzh_down:
    stx tptr+1
    lsr tptr+1
    ror
    ldx tptr+1
    dey
    bne @rzh_down
:
    rts

; Exact rare-path fraction: A = min(255, ((near-zBehind) << 8) / dz).
; The reciprocal projection table intentionally clamps z<16 and cannot be
; reused here now that wall geometry clips at four units.
clip_frac:
    lda #0
    sta tclip
    ldx #8
@bit:
    asl mul_a
    rol mul_a+1
    asl tclip
    lda mul_a+1
    cmp rt_acc+1
    bcc @next
    bne @subtract
    lda mul_a
    cmp rt_acc
    bcc @next
@subtract:
    lda mul_a
    sec
    sbc rt_acc
    sta mul_a
    lda mul_a+1
    sbc rt_acc+1
    sta mul_a+1
    inc tclip
@next:
    dex
    bne @bit
    lda tclip
    rts

shift3_cx:              ; hi16(mul_r) >> 3 signed -> A=lo X=hi
    .repeat 3
    lda mul_r+3
    cmp #$80
    ror mul_r+3
    ror mul_r+2
    .endrepeat
    lda mul_r+2
    ldx mul_r+3
    rts

mul_h_rzh:              ; A = h (SIGNED) -> A/X = (h * rzh1) >> 8, signed
    sta mul_a
    lda rzh1
    sta mul_b
    lda rzh1+1
    sta mul_b+1
    jsr mul8s16u
    lda mul_r+1
    ldx mul_r+2
    rts

mul_h_step:             ; A = h (SIGNED) -> A/X = (h * rzstep) >> 8, signed
    sta mul_a
    lda rzstep
    sta mul_b
    lda rzstep+1
    sta mul_b+1
    jsr mul8s16s
    lda mul_r+1
    ldx mul_r+2
    rts

.ifdef E1M1

; Sprite scratch aliases are only live while no wall is being processed.
spr_class  = cx1
spr_entry  = cx1+1
spr_cell_x = cx2
spr_cell_y = cx2+1
spr_tmp    = ulen
spr_toprow = tclip

shot_damage:
    .byte 5, 10, 15

; A = high byte of a four-page OAM set. Each page is initialized with one
; generated weapon frame; unused weapon-envelope and world slots stay hidden.
init_oam_set:
    sta spr_oam_ptr+1
    lda #0
    sta spr_oam_ptr
    sta spr_class
@frame:
    lda #$FF
    ldy #0
@hide:
    sta (spr_oam_ptr),y
    iny
    bne @hide

    ldx spr_class
    lda weapon_frame_first,x
    sta tptr
    lda #0
    sta tptr+1
    asl tptr
    rol tptr+1
    asl tptr
    rol tptr+1
    lda tptr
    clc
    adc #<weapon_oam
    sta tptr
    lda tptr+1
    adc #>weapon_oam
    sta tptr+1
    lda weapon_frame_count,x
    asl
    asl
    sta spr_cells_left
    ldy #0
@copy:
    lda (tptr),y
    sta (spr_oam_ptr),y
    iny
    dec spr_cells_left
    bne @copy
    inc spr_oam_ptr+1
    inc spr_class
    lda spr_class
    cmp #<WEAPON_FRAME_COUNT
    bne @frame
    rts

; Collect pickups after movement so gameplay state and the following render
; pass observe the same camera position. Distances are s11.4: a 16-unit radius
; has squared radius 65536, represented by carry from the 16-bit square sum.
collect_pickups:
    ldx #0
@thing:
    cpx #<MAP_THING_COUNT
    bcc :+
    rts
:
    stx spr_thing
    jsr thing_is_active
    bne :+
    jmp @next
:
    ldy spr_thing
    lda thing_kind,y
    cmp #3
    bcc :+
    jmp @next
:

    lda thing_x_lo,y
    sec
    sbc px
    sta rt_dx
    lda thing_x_hi,y
    sbc px+1
    sta rt_dx+1
    bpl @xabs
    lda #0
    sec
    sbc rt_dx
    sta rt_dx
    lda #0
    sbc rt_dx+1
    sta rt_dx+1
@xabs:
    lda rt_dx+1
    beq :+
    jmp @next
:
    lda rt_dx
    sta spr_cell_x

    lda thing_y_lo,y
    sec
    sbc py
    sta rt_dy
    lda thing_y_hi,y
    sbc py+1
    sta rt_dy+1
    bpl @yabs
    lda #0
    sec
    sbc rt_dy
    sta rt_dy
    lda #0
    sbc rt_dy+1
    sta rt_dy+1
@yabs:
    lda rt_dy+1
    beq :+
    jmp @next
:
    lda rt_dy
    sta spr_cell_y

    lda spr_cell_x
    sta MMC5_MULT_A
    sta MMC5_MULT_B
    lda MMC5_MULT_A
    sta rt_acc
    lda MMC5_MULT_B
    sta rt_acc+1
    lda spr_cell_y
    sta MMC5_MULT_A
    sta MMC5_MULT_B
    lda MMC5_MULT_A
    clc
    adc rt_acc
    lda MMC5_MULT_B
    adc rt_acc+1
    bcs @next

    ldy spr_thing
    lda thing_kind,y
    beq @health
    cmp #1
    beq @bonus_armor
    ; ARM2 is left in the world when it cannot improve armor.
    lda PL_ARMOR
    cmp #200
    bcs @next
    lda #200
    sta PL_ARMOR
    lda #2
    sta PL_ARMOR_TYPE
    bne @consume
@health:
    lda PL_HEALTH
    cmp #200
    bcs @consume
    inc PL_HEALTH
    bne @consume
@bonus_armor:
    lda PL_ARMOR
    cmp #200
    bcs :+
    inc PL_ARMOR
:   lda PL_ARMOR_TYPE
    bne @consume
    lda #1
    sta PL_ARMOR_TYPE
@consume:
    lda spr_thing
    and #7
    tax
    lda pickup_bits,x
    eor #$FF
    sta spr_tmp
    lda spr_thing
    lsr
    lsr
    lsr
    tay
    lda THING_ACTIVE,y
    and spr_tmp
    sta THING_ACTIVE,y
    lda #1
    sta HUD_DIRTY
    inc PICKUP_COUNT
@next:
    ldx spr_thing
    inx
    beq @done
    jmp @thing
@done:
    rts

thing_is_active:
    lda spr_thing
    lsr
    lsr
    lsr
    tay
    lda THING_ACTIVE,y
    sta spr_tmp
    lda spr_thing
    and #7
    tay
    lda pickup_bits,y
    and spr_tmp
    rts

pickup_bits:
    .byte $01, $02, $04, $08, $10, $20, $40, $80

; Expiration is simulation state, not visibility state. Scan every render so
; offscreen death animations cannot wrap their byte-sized ages and replay.
expire_explosions:
    ldx #0
@thing:
    cpx #<MAP_THING_COUNT
    bcs @done
    stx spr_thing
    jsr thing_is_active
    beq @next
    ldy spr_thing
    lda thing_kind,y
    cmp #3
    beq @dead_kind
    cmp #4
    bne @next
@dead_kind:
    sta spr_frame
    lda THING_HEALTH,y
    bne @next
    ldx #60
    lda spr_frame
    cmp #4
    bne :+
    ldx #96
:   txa
    sta spr_tmp
    lda rf_t0
    sec
    sbc THING_DEATH_AT,y
    cmp spr_tmp
    bcc @next
    lda spr_thing
    and #7
    tay
    lda pickup_bits,y
    eor #$FF
    sta spr_tmp
    lda spr_thing
    lsr
    lsr
    lsr
    tay
    lda THING_ACTIVE,y
    and spr_tmp
    sta THING_ACTIVE,y
@next:
    ldx spr_thing
    inx
    bne @thing
@done:
    rts

; Prepare all four pages in the OAM set paired with the back compose buffer.
; The weapon owns 0..WEAPON_SLOT_CAP-1; world records mirror across pages.
sprite_frame_begin:
    lda #0
    sta spr_oam_ptr
    ldx rf_back
    lda BUFA_OAM_SET,x
    sta spr_oam_ptr+1
    ldx #<WEAPON_FRAME_COUNT
@frame:
    lda #$FF
    ldy #<(WEAPON_SLOT_CAP * 4)
@hide:
    sta (spr_oam_ptr),y
    iny
    bne @hide
    inc spr_oam_ptr+1
    dex
    bne @frame
    lda spr_oam_ptr+1
    sec
    sbc #<WEAPON_FRAME_COUNT
    sta spr_oam_ptr+1
    lda #<(WEAPON_SLOT_CAP * 4)
    sta spr_oam_off

    ; The generated maximum envelope is safe for every dynamic weapon frame.
    ldx #0
@counts:
    lda weapon_scan_count,x
    sta spr_scan_count,x
    inx
    cpx #160
    bne @counts
    rts

; Called by the near-to-far BSP walk after leaf culling, before the leaf's
; walls narrow ceil_clip/floor_clip. Existing clips therefore represent only
; geometry in front of these things.
draw_subsector_things:       ; X = subsector
    stx spr_current_ss
    lda ss_sector,x
    tax
    lda sec_floor,x
    sta spr_floor
    ldx spr_current_ss
    lda ss_thing_count,x
    beq @monsters
    sta spr_things_left
    lda ss_thing_first,x
    sta spr_thing
    lda #$FF
    sta spr_monster
@thing:
    ldy spr_thing
    lda thing_kind,y
    cmp #4
    beq @static_next
    jsr project_world_thing
@static_next:
    inc spr_thing
    dec spr_things_left
    bne @thing
@monsters:
    ldx #0
@monster:
    cpx #<MONSTER_COUNT
    bcs @done
    stx spr_monster
    lda MONSTER_SS,x
    cmp spr_current_ss
    bne @monster_next
    lda monster_thing_idx,x
    sta spr_thing
    jsr project_world_thing
@monster_next:
    ldx spr_monster
    inx
    bne @monster
@done:
    rts

project_world_thing:
    jsr thing_is_active
    bne :+
    rts
:
    ldy spr_thing
    lda thing_kind,y
    cmp #4
    bne @static_position
    ldx spr_monster
    lda MONSTER_X_LO,x
    sta wx
    lda MONSTER_X_HI,x
    sta wx+1
    lda MONSTER_Y_LO,x
    sta wy
    lda MONSTER_Y_HI,x
    sta wy+1
    jmp @position_ready
@static_position:
    lda thing_x_lo,y
    sta wx
    lda thing_x_hi,y
    sta wx+1
    lda thing_y_lo,y
    sta wy
    lda thing_y_hi,y
    sta wy+1
@position_ready:
    jsr sub_cam
    jsr zdot
    lda ttz+1
    bpl :+
    rts
:
    cmp #>SPRITE_NEAR
    bcs :+
    rts
:
    bne @depth_ok
    lda ttz
    cmp #<SPRITE_NEAR
    bcs @depth_ok
    rts
@depth_ok:
    jsr xdot
    jsr rzh_lookup
    sta rzh1
    stx rzh1+1

    ; Screen center X = 128 + hi16(lateral * reciprocal depth).
    lda ttx
    sta mul_a
    lda ttx+1
    sta mul_a+1
    lda rzh1
    sta mul_b
    lda rzh1+1
    sta mul_b+1
    jsr mul16s16u
    lda mul_r+2
    clc
    adc #128
    sta spr_x
    lda mul_r+3
    adc #0
    beq :+
    rts
:
    lda spr_x
    and #$F8
    sta spr_x

    ; Project native thing height and choose its 8/16/32-pixel bake.
    ldy spr_thing
    lda thing_kind,y
    tax
    lda world_kind_world_h,x
    sta mul_a
    lda rzh1
    sta mul_b
    lda rzh1+1
    sta mul_b+1
    jsr mul8u16u
    .repeat 4
    lsr mul_r+2
    ror mul_r+1
    ror mul_r
    .endrepeat
    lda mul_r+1
    cmp #4
    bcs :+
    rts
:
    ldx #0
    cmp #12
    bcc @class_ready
    inx
    cmp #24
    bcc @class_ready
    inx
@class_ready:
    stx spr_class

    ; Floor baseline Y = horizon + (eye-floor) * reciprocal depth / 4096.
    lda eye_h
    sec
    sbc spr_floor
    sta mul_a
    lda rzh1
    sta mul_b
    lda rzh1+1
    sta mul_b+1
    jsr mul8s16u
    .repeat 4
    lda mul_r+3
    cmp #$80
    ror mul_r+3
    ror mul_r+2
    ror mul_r+1
    ror mul_r
    .endrepeat
    lda mul_r+1
    clc
    adc #80
    sta spr_y
    lda mul_r+2
    adc #0
    beq :+
    rts
:
    lda spr_y
    and #$F8
    sta spr_y

    ; Hitscan admission uses the BSP clip at the center column, independent
    ; of metasprite cell/OAM capacity. Dead barrels remain for BEXP rendering
    ; but can no longer become candidates.
    jsr consider_shot_candidate

    ldy spr_thing
    lda thing_kind,y
    cmp #3
    beq @barrel
    cmp #4
    beq @zombie
    jmp @normal_sprite
@barrel:
    lda THING_HEALTH,y
    beq :+
    jmp @normal_sprite
:
    lda rf_t0
    sec
    sbc THING_DEATH_AT,y
    cmp #60
    bcc @explosion_frame
    lda spr_thing
    and #7
    tax
    lda pickup_bits,x
    eor #$FF
    sta spr_tmp
    lda spr_thing
    lsr
    lsr
    lsr
    tay
    lda THING_ACTIVE,y
    and spr_tmp
    sta THING_ACTIVE,y
    rts

@explosion_frame:
    ldx #0
    cmp #9
    bcc @explosion_entry
    inx
    cmp #17
    bcc @explosion_entry
    inx
    cmp #26
    bcc @explosion_entry
    inx
    cmp #43
    bcc @explosion_entry
    inx
@explosion_entry:
    txa
    asl                     ; frame * 2 + min(scale class, 1)
    ldx spr_class
    beq :+
    clc
    adc #1
:   tay
    lda #1
    sta spr_exploding
    lda #0
    sta spr_exp_emitted
    inc EXPLOSION_RENDER_COUNT
    lda barrel_exp_meta_first,y
    sta spr_entry
    lda barrel_exp_meta_count,y
    sta spr_cells_left
    bne @cell

@zombie:
    lda #0
    sta spr_exploding
    lda THING_HEALTH,y
    beq @zombie_dead
    ldx spr_monster
    lda rf_t0
    sec
    sbc MONSTER_LAST_ATTACK,x
    cmp #16
    bcs @zombie_walk
    ldx #2
    cmp #8
    bcc @zombie_frame_ready
    inx
    bne @zombie_frame_ready
@zombie_walk:
    lda rf_t0
    lsr
    lsr
    lsr
    and #1
    tax
    jmp @zombie_frame_ready
@zombie_dead:
    lda rf_t0
    sec
    sbc THING_DEATH_AT,y
    ldx #4
    cmp #16
    bcc @zombie_frame_ready
    inx
    cmp #40
    bcc @zombie_frame_ready
    inx
@zombie_frame_ready:
    stx spr_frame
    ldx #4
    jmp @world_metadata

    ; Metadata is ordered kind, animation frame, scale class.
@normal_sprite:
    lda #0
    sta spr_exploding
    ldy spr_thing
    lda thing_kind,y
    tax
    lda world_kind_frame_mask,x
    sta spr_tmp
    lda rf_t0
    lsr
    lsr
    lsr
    and spr_tmp
    sta spr_frame
@world_metadata:
    lda spr_frame
    sta spr_entry
    asl
    clc
    adc spr_entry          ; frame * 3
    adc spr_class
    adc world_kind_meta_base,x
    tay
    lda world_meta_first,y
    sta spr_entry
    lda world_meta_count,y
    sta spr_cells_left
@cell:
    jsr emit_world_cell
    inc spr_entry
    dec spr_cells_left
    bne @cell
    lda spr_exploding
    beq @out
    lda spr_exp_emitted
    beq @out
    jsr queue_explosion_sound
@out:
    rts

; Queue the report with the first composed BEXP frame, exactly once for this
; thing. The pusher publishes the flag with the matching OAM set.
queue_explosion_sound:
    lda spr_thing
    and #7
    tay
    lda pickup_bits,y
    sta spr_tmp
    lda spr_thing
    lsr
    lsr
    lsr
    tay
    lda THING_EXP_SOUND_SENT,y
    and spr_tmp
    bne @done
    lda THING_EXP_SOUND_SENT,y
    ora spr_tmp
    sta THING_EXP_SOUND_SENT,y
    ldx rf_back
    lda #1
    sta BUFA_EXPLOSION_SOUND,x
@done:
    rts

; Admit a live barrel or zombieman under the pistol's center ray when its class
; overlaps the center-column opening left by nearer BSP geometry.
consider_shot_candidate:
    lda SHOT_PENDING
    bne :+
    rts
:
    ldy spr_thing
    lda thing_kind,y
    cmp #3
    beq @shootable
    cmp #4
    beq @shootable
    rts
@shootable:
    sta spr_frame
    lda THING_HEALTH,y
    beq @out
    lda ttz+1
    cmp #$33
    bcc @range_ok
    bne @out
    lda ttz
    cmp #$34
    bcs @out
@range_ok:
    lda spr_frame
    cmp #4
    beq @zombie_lateral
    lda ttx+1
    beq @lateral_positive
    cmp #$FF
    bne @out
    lda ttx
    cmp #$C0
    bcc @out
    bcs @clip_test
@lateral_positive:
    lda ttx
    cmp #$41
    bcs @out
    bcc @clip_test
@zombie_lateral:
    lda ttx+1
    beq @zombie_positive
    cmp #$FF
    bne @out
    lda ttx
    cmp #$80
    bcc @out
    bcs @clip_test
@zombie_positive:
    lda ttx
    cmp #$81
    bcs @out
@clip_test:
    lda spr_y
    lsr
    lsr
    lsr
    sta spr_tmp             ; projected floor baseline in tile rows
    cmp ceil_clip+16
    beq @out
    bcc @out
    ldx spr_class
    sec
    sbc shot_class_rows,x
    bcc @nearest
    cmp floor_clip+16
    bcs @out
@nearest:
    lda ttz+1
    cmp SHOT_BEST_HI
    bcc @select
    bne @out
    lda ttz
    cmp SHOT_BEST_LO
    bcs @out
@select:
    lda ttz
    sta SHOT_BEST_LO
    lda ttz+1
    sta SHOT_BEST_HI
    lda spr_thing
    sta SHOT_TARGET
@out:
    rts

shot_class_rows:
    .byte 1, 2, 4

; Apply one canonical pistol roll per latched shot to the selected actor.
; Once it dies, remaining shots in this renderer batch have no live target.
resolve_pending_shots:
    lda SHOT_PENDING
    beq shot_done
    lda SHOT_TARGET
    cmp #$FF
    beq @miss
    tay
@hit:
    inc HIT_COUNT
    jsr roll_shot_damage
    cmp THING_HEALTH,y
    bcs shot_kill
    sta spr_tmp
    lda THING_HEALTH,y
    sec
    sbc spr_tmp
    sta THING_HEALTH,y
    dec SHOT_PENDING
    bne @hit
    beq shot_done
@miss:
    ; Doom rolls damage before tracing, so misses advance the sequence too.
    jsr roll_shot_damage
    dec SHOT_PENDING
    bne @miss
    beq shot_done
shot_kill:
    lda #0
    sta THING_HEALTH,y
    lda rf_t0
    sta THING_DEATH_AT,y
    lda thing_kind,y
    cmp #3
    bne :+
    inc BARREL_KILLS
    jmp shot_clear
:   inc ZOMBIE_KILLS
shot_clear:
    lda #0
    sta SHOT_PENDING
shot_done:
    rts

roll_shot_damage:
@reroll:
    lda rng
    lsr
    bcc :+
    eor #$B8
:   sta rng
    and #3
    cmp #3
    beq @reroll
    tax
    lda shot_damage,x
    rts

emit_world_cell:
    lda spr_oam_off
    cmp #$FC               ; reserve the final record instead of wrapping
    bcc :+
    rts
:
    ldy spr_entry

    ; Signed grid offset plus projected origin, rejecting 8-bit overflow.
    lda spr_exploding
    beq :+
    lda barrel_exp_dx,y
    jmp @have_dx
:   lda world_sprite_dx,y
@have_dx:
    bmi @xneg
    clc
    adc spr_x
    bcc @xready
    rts
@xneg:
    clc
    adc spr_x
    bcs @xready
    rts
@xready:
    cmp #249
    bcc :+
    rts
:
    sta spr_cell_x

    lda spr_exploding
    beq :+
    lda barrel_exp_dy,y
    jmp @have_dy
:   lda world_sprite_dy,y
@have_dy:
    bmi @yneg
    clc
    adc spr_y
    bcc @yready
    rts
@yneg:
    clc
    adc spr_y
    bcs @yready
    rts
@yready:
    cmp #0                ; OAM Y=$FF is the hidden-sprite sentinel
    bne :+
    rts
:
    cmp #145              ; complete 16-pixel sprite must end in the view
    bcc :+
    rts
:
    sta spr_cell_y

    ; Both 8-pixel halves must fit the clip window at this screen column.
    lda spr_cell_x
    lsr
    lsr
    lsr
    tax
    lda spr_cell_y
    lsr
    lsr
    lsr
    sta spr_toprow
    cmp ceil_clip,x
    bcs :+
    rts
:
    clc
    adc #1
    cmp floor_clip,x
    bcc :+
    rts
:
    ; Enforce the hardware's eight-sprites-per-scanline limit in software.
    ldx spr_cell_y
    ldy #16
@test_line:
    lda spr_scan_count,x
    cmp #8
    bcs @out
    inx
    dey
    bne @test_line

    ldy spr_entry
    lda spr_exploding
    beq :+
    lda barrel_exp_tile,y
    jmp @have_tile
:   lda world_sprite_tile,y
@have_tile:
    sta spr_tmp
    lda spr_exploding
    beq :+
    lda barrel_exp_attr,y
    jmp @have_attr
:   lda world_sprite_attr,y
@have_attr:
    sta spr_toprow
    ldy spr_oam_off
    lda spr_cell_y
    sec
    sbc #1
    jsr write_oam_all
    iny
    lda spr_tmp
    jsr write_oam_all
    iny
    lda spr_toprow
    jsr write_oam_all
    iny
    lda spr_cell_x
    jsr write_oam_all
    iny
    sty spr_oam_off
    lda spr_exploding
    beq :+
    lda #1
    sta spr_exp_emitted
    inc EXPLOSION_OAM_COUNT
:

    ldx spr_cell_y
    ldy #16
@claim_line:
    inc spr_scan_count,x
    inx
    dey
    bne @claim_line
@out:
    rts

; Store one world-record byte at the same offset in every weapon-frame page.
write_oam_all:
    sta (spr_oam_ptr),y
    inc spr_oam_ptr+1
    sta (spr_oam_ptr),y
    inc spr_oam_ptr+1
    sta (spr_oam_ptr),y
    inc spr_oam_ptr+1
    sta (spr_oam_ptr),y
    pha
    lda spr_oam_ptr+1
    sec
    sbc #3
    sta spr_oam_ptr+1
    pla
    rts

.endif

; ---------------------------------------------------------------------------
; div_u: mtmp+2/3 = (uoz_acc << 16) / rzh1 — the exact perspective u at the
; interpolants' current position. Restoring division, 16 bits: the quotient
; fits because u < 256 texels guarantees uoz < rzh, and both interpolate
; linearly so the invariant holds at every column. ~420 cycles.
; Clobbers mtmp, A, X, Y.
; ---------------------------------------------------------------------------
div_u:
    lda uoz_acc
    sta mtmp            ; remainder = dividend high word (low word is 0)
    lda uoz_acc+1
    sta mtmp+1
    ldx #16
@dl:
    asl mtmp
    rol mtmp+1
    bcs @sub            ; 17-bit remainder: subtract unconditionally
    lda mtmp
    sec
    sbc rzh1
    tay
    lda mtmp+1
    sbc rzh1+1
    bcs @take
    clc                 ; remainder < divisor: quotient bit 0
    bcc @q
@sub:
    lda mtmp
    sec
    sbc rzh1
    tay
    lda mtmp+1
    sbc rzh1+1
@take:
    sta mtmp+1
    sty mtmp
    sec                 ; quotient bit 1
@q:
    rol mtmp+2
    rol mtmp+3
    dex
    bne @dl
    rts

; ---------------------------------------------------------------------------
; chunk_u: perspective-u anchor. Snaps uacc exact at the current column,
; then looks ahead 8 columns (advance interpolant copies, divide again) and
; sets ustep so the affine run lands EXACTLY on the next anchor — u is
; continuous piecewise-linear through exact points. The old scheme kept the
; whole-seg slope and snapped at each resync: a visible phase pop marching
; across strong-perspective walls. Segs with < 8 columns left get exact
; per-column anchors instead (persp_cnt stays 0).
; ---------------------------------------------------------------------------
chunk_u:
    jsr div_u
    lda mtmp+2
    sta uacc
    lda mtmp+3
    sta uacc+1
    lda col_r
    sec
    sbc cur_col
    cmp #9
    bcs :+
    rts                 ; tail: per-column exact until the seg ends
:
    ; save interpolants, advance both copies by 8 columns
    lda rzh1
    pha
    lda rzh1+1
    pha
    lda uoz_acc
    pha
    lda uoz_acc+1
    pha
    lda rzstep
    sta ttx             ; ttx/ttz free here: 8*step scratch
    lda rzstep+1
    sta ttx+1
    lda uoz_step
    sta ttz
    lda uoz_step+1
    sta ttz+1
    .repeat 3
    asl ttx
    rol ttx+1
    asl ttz
    rol ttz+1
    .endrepeat
    lda rzh1
    clc
    adc ttx
    sta rzh1
    lda rzh1+1
    adc ttx+1
    sta rzh1+1
    lda uoz_acc
    clc
    adc ttz
    sta uoz_acc
    lda uoz_acc+1
    adc ttz+1
    sta uoz_acc+1
    jsr div_u           ; mtmp+2/3 = u at the next anchor
    pla
    sta uoz_acc+1
    pla
    sta uoz_acc
    pla
    sta rzh1+1
    pla
    sta rzh1
    ; ustep = (u_next - uacc) >> 3, signed
    lda mtmp+2
    sec
    sbc uacc
    sta ustep
    lda mtmp+3
    sbc uacc+1
    sta ustep+1
    .repeat 3
    lda ustep+1
    cmp #$80
    ror ustep+1
    ror ustep
    .endrepeat
    lda #8
    sta persp_cnt
    rts

clamp60:                ; signed A -> clamped to [-60, 60]. 60 covers every
    bpl @pos            ; reachable span: near clip (16u) caps full-height
    cmp #<-60           ; walls at ~51 rows; only ultra-tall sectors right at
    bcs @done           ; the clip can still saturate.
    lda #<-60
    rts
@pos:
    cmp #61
    bcc @done
    lda #60
@done:
    rts

clamp_row:              ; signed A -> clamped to [0, VIEW_ROWS]
    bmi @zero
    cmp #VIEW_ROWS+1
    bcc @done
    lda #VIEW_ROWS
@done:
    rts
@zero:
    lda #0
    rts

; fetch_vertex: Y = record offset of a vertex index -> wx/wy. Full-map segs
; keep endpoint high bytes at offsets 10 and 11 to preserve all old fields.
fetch_vertex:
    lda (wall_ptr),y
    sta tptr
.ifdef FULL_E1M1
    cpy #0
    bne :+
    ldy #10
    bne @have_high_offset
:   ldy #11
@have_high_offset:
    lda (wall_ptr),y
    sta tptr+1
.else
    lda #0
    sta tptr+1
.endif
    asl tptr
    rol tptr+1
    asl tptr
    rol tptr+1          ; *4
    lda tptr
    clc
    adc #<map_verts
    sta tptr
    lda tptr+1
    adc #>map_verts
    sta tptr+1
.ifdef FULL_E1M1
    lda #MAP_GEOM_BANK
    sta MMC5_PRG_A000
.endif
    ldy #0
    lda (tptr),y
    sta wx
    iny
    lda (tptr),y
    sta wx+1
    iny
    lda (tptr),y
    sta wy
    iny
    lda (tptr),y
    sta wy+1
.ifdef FULL_E1M1
    lda #MAP_COMMON_BANK
    sta MMC5_PRG_A000
.endif
    rts

; set slice-LUT base pointers for a texture slot in A; X selects which pair
; (0 = mid/upper -> sl_tp/sl_bp, 4 = lower -> sl_tp_l/sl_bp_l).
; (The palette ramp bit rides bit 7 of each slice_bank LUT byte.)
set_texptrs:
    and #$0F            ; high bit marks collision-blocking segs
    cpx #0
    bne @lower_slot
    sta sl_tex
    jmp @slot_done
@lower_slot:
    sta sl_tex_l
@slot_done:
    tay
    lda tex_max_class,y
    sta sl_mc,x
    lda tex_vperiod,y
    sta sl_vp,x
    lda tex_base_lo,y
    clc
    adc #<slice_tile
    sta sl_tp,x
    lda tex_base_hi,y
    adc #>slice_tile
    sta sl_tp+1,x
    lda tex_base_lo,y
    clc
    adc #<slice_bank
    sta sl_bp,x
    lda tex_base_hi,y
    adc #>slice_bank
    sta sl_bp+1,x
    rts

; ---------------------------------------------------------------------------
; vert_angle: A/X = vertex index high/low. Returns
; A = view angle of the vertex (BAM hi-byte) with C clear, or C set when the
; vertex is too close for a reliable atan. Low indices use the 256-entry
; generation cache; full-map high indices use a tagged eight-entry side cache.
; ---------------------------------------------------------------------------
vert_angle:
    sta vmask
    stx vtmp
.ifdef FULL_E1M1
    ora #0
    beq @low_lookup
    ldy #1
    sty FULL_HIGH_VERTEX_SEEN
    lda vtmp
    eor vmask
    and #7
    tax
    lda hvstamp,x
    cmp vang_gen
    bne @compute_uncached
    lda hvindex_lo,x
    cmp vtmp
    bne @compute_uncached
    lda hvindex_hi,x
    cmp vmask
    bne @compute_uncached
    lda hvflags,x
    bmi @near
    lda hvang,x
    clc
    rts
@low_lookup:
.endif
    lda vstamp,x
    cmp vang_gen
    bne @compute
    lda vflags,x
    bmi @near
    lda vang,x
    clc
    rts
@near:
    sec
    rts
@compute:
    lda vang_gen
    sta vstamp,x
@compute_uncached:
    ; rt_dx/rt_dy = vertex - camera (map_verts is 4-byte records)
    lda vmask
    sta tptr+1
    lda vtmp
    asl
    rol tptr+1
    asl
    rol tptr+1
    clc
    adc #<map_verts
    sta tptr
    lda tptr+1
    adc #>map_verts
    sta tptr+1
.ifdef FULL_E1M1
    lda #MAP_GEOM_BANK
    sta MMC5_PRG_A000
.endif
    ldy #0
    lda (tptr),y
    sec
    sbc px
    sta rt_dx
    iny
    lda (tptr),y
    sbc px+1
    sta rt_dx+1
    iny
    lda (tptr),y
    sec
    sbc py
    sta rt_dy
    iny
    lda (tptr),y
    sbc py+1
    sta rt_dy+1
.ifdef FULL_E1M1
    lda #MAP_COMMON_BANK
    sta MMC5_PRG_A000
.endif
    jsr atan2_hi
    bcs @toonear
.ifdef FULL_E1M1
    ldx vmask
    bne @uncached_ok
.endif
    ldx vtmp
    sta vang,x
    lda #0
    sta vflags,x
    lda vang,x
    clc
    rts
.ifdef FULL_E1M1
@uncached_ok:
    pha
    lda vtmp
    eor vmask
    and #7
    tax
    lda vtmp
    sta hvindex_lo,x
    lda vmask
    sta hvindex_hi,x
    lda #0
    sta hvflags,x
    pla
    sta hvang,x
    lda vang_gen         ; publish the cache entry last
    sta hvstamp,x
    lda hvang,x
    clc
    rts
.endif
@toonear:
.ifdef FULL_E1M1
    ldx vmask
    bne @uncached_near
.endif
    ldx vtmp
    lda #$80
    sta vflags,x
    sec
    rts
.ifdef FULL_E1M1
@uncached_near:
    lda vtmp
    eor vmask
    and #7
    tax
    lda vtmp
    sta hvindex_lo,x
    lda vmask
    sta hvindex_hi,x
    lda #$80
    sta hvflags,x
    lda vang_gen
    sta hvstamp,x
    sec
    rts
.endif

; seg_deltas: camera-relative deltas of both endpoints -> dx1/dy1 (v1),
; rt_dx/rt_dy (v2)
seg_deltas:
    ldy #0
    jsr fetch_vertex
    jsr sub_cam
    lda rt_dx
    sta dx1
    lda rt_dx+1
    sta dx1+1
    lda rt_dy
    sta dy1
    lda rt_dy+1
    sta dy1+1
    ldy #2
    jsr fetch_vertex
    jmp sub_cam

; ---------------------------------------------------------------------------
; do_seg: rasterize one seg from (wall_ptr). Record layout (10 bytes):
; v1/v2 + V phases, ulen, u0, tex|blocking, tex_low, front, back
;
; Angle gate (Doom's R_AddLine): cached per-vertex angles decide backface /
; off-frustum / fully-occluded before any transform math. Only segs that
; survive (or whose angles are unreliable) touch the multiplier.
; ---------------------------------------------------------------------------
do_seg:
.ifdef FULL_E1M1
    ldy #10
    lda (wall_ptr),y
    sta vmask
    ldy #0
    lda (wall_ptr),y
    tax
    lda vmask
.else
    ldy #0
    lda (wall_ptr),y
    tax
    lda #0
.endif
    jsr vert_angle
    bcs @gf
    sta seg_a1
.ifdef FULL_E1M1
    ldy #11
    lda (wall_ptr),y
    sta vmask
    ldy #2
    lda (wall_ptr),y
    tax
    lda vmask
.else
    ldy #2
    lda (wall_ptr),y
    tax
    lda #0
.endif
    jsr vert_angle
    bcs @gf
    sta seg_a2
    lda seg_a1
    sec
    sbc seg_a2
    sta pf_span         ; angular span (mod 256); true front-facing < 128
    ; +-4 units of atan slack: 133..251 is certain backface; 124..132 is the
    ; wall-hugging wrap zone (true span ~180deg) where the clip tests below
    ; are invalid -> exact path. Small spans run the frustum/occlusion tests
    ; (winding settled by the exact backface test later); tiny negative
    ; spans normalize order first.
    cmp #124
    bcc @pf_ord
    cmp #133
    bcc @gf
    cmp #252
    bcs @pf_swap
    rts                 ; certain backface
@gf:
    jmp @gate_full      ; angles unreliable -> exact path
@pf_swap:
    ; measured span slightly negative (sliver): swap endpoints so a1 is left
    lda #0
    sec
    sbc pf_span
    sta pf_span
    ldx seg_a1
    lda seg_a2
    sta seg_a1
    stx seg_a2
@pf_ord:
    ; left endpoint: idx1 = (a1 - pang) + PF_CLIP, on-screen in [0, 2*CLIP]
    lda seg_a1
    sec
    sbc pang+1
    clc
    adc #PF_CLIP
    cmp #2*PF_CLIP+1
    bcc @pf_a1ok
    ; outside: reject unless the seg wraps back in.
    ; tspan = idx1 - 2*CLIP; off-screen if tspan - 4 >= span (4 = atan slack)
    sec
    sbc #2*PF_CLIP
    sec
    sbc #4
    bcc @pf_a1cl
    cmp pf_span
    bcc @pf_a1cl
    rts                 ; entirely off the left / behind
@pf_a1cl:
    lda #2*PF_CLIP      ; clamp to the left frustum edge
@pf_a1ok:
    sta pf_c
    ; right endpoint: idx2 = (a2 - pang) + PF_CLIP
    lda seg_a2
    sec
    sbc pang+1
    clc
    adc #PF_CLIP
    cmp #2*PF_CLIP+1
    bcc @pf_a2ok
    ; tspan = -idx2 (mod 256); off-screen if tspan - 4 >= span
    eor #$FF
    sec
    sbc #3              ; (255 - idx2) - 3 = (256 - idx2) - 4
    bcc @pf_a2cl
    cmp pf_span
    bcc @pf_a2cl
    rts                 ; entirely off the right
@pf_a2cl:
    lda #0              ; clamp to the right frustum edge
@pf_a2ok:
    tay
    lda angcol_tbl,y    ; right column + slack
    clc
    adc #2
    cmp #32
    bcc :+
    lda #31
:   sta pf_r
    ldy pf_c
    lda angcol_tbl,y    ; left column - slack
    sec
    sbc #2
    bcs :+
    lda #0
:   tay
@pf_occ:
    lda ceil_clip,y
    cmp floor_clip,y
    bcc @pf_open        ; open column -> seg may be visible
    cpy pf_r
    iny
    bcc @pf_occ
    rts                 ; every reachable column already solid -> skip seg
@pf_open:
    ; angle gate passed. Span 5..123 (with +-4 slack) is certainly
    ; front-facing: skip the exact backface multiplies. Slivers and
    ; ambiguous spans still get the exact winding test.
    lda pf_span
    cmp #5
    bcc @gate_full
    cmp #124
    bcs @gate_full
    jsr seg_deltas
    jmp @facing
@gate_full:
    jsr seg_deltas      ; rt_dx/rt_dy = v2 deltas from here on
    ; --- exact backface: camera must be on the seg's right (front) side.
    ; cross = segdy*dx1 - segdx*dy1; reject when >= 0. Two multiplies on raw
    ; deltas — kills back-facing segs before any transform work.
    lda rt_dy
    sec
    sbc dy1
    sta mul_a           ; segdy
    lda rt_dy+1
    sbc dy1+1
    sta mul_a+1
    lda dx1
    sta mul_b
    lda dx1+1
    sta mul_b+1
    jsr mul16s
    lda mul_r
    sta rt_acc
    lda mul_r+1
    sta rt_acc+1
    lda mul_r+2
    pha
    lda mul_r+3
    pha
    lda rt_dx
    sec
    sbc dx1
    sta mul_a           ; segdx
    lda rt_dx+1
    sbc dx1+1
    sta mul_a+1
    lda dy1
    sta mul_b
    lda dy1+1
    sta mul_b+1
    jsr mul16s
    lda rt_acc
    sec
    sbc mul_r
    lda rt_acc+1
    sbc mul_r+1
    pla                 ; P1 byte 3 (PLA preserves carry)
    tax
    pla                 ; P1 byte 2
    sbc mul_r+2
    txa
    sbc mul_r+3
    bmi @facing
    rts
@facing:
    lda rt_dx
    sta dx2
    lda rt_dx+1
    sta dx2+1
    lda rt_dy
    sta dy2
    lda rt_dy+1
    sta dy2+1
    ; z-first: both depths before the lateral transform
    jsr zdot
    lda ttz
    sta tz2
    lda ttz+1
    sta tz2+1
    lda dx1
    sta rt_dx
    lda dx1+1
    sta rt_dx+1
    lda dy1
    sta rt_dy
    lda dy1+1
    sta rt_dy+1
    jsr zdot
    lda ttz
    sta tz1
    lda ttz+1
    sta tz1+1
    ; both endpoints behind the near plane -> out
    lda tz1
    sec
    sbc #<WALL_NEAR
    lda tz1+1
    sbc #>WALL_NEAR
    bpl @infront
    lda tz2
    sec
    sbc #<WALL_NEAR
    lda tz2+1
    sbc #>WALL_NEAR
    bpl @infront
    rts
@infront:
    jsr xdot            ; v1 deltas still loaded
    lda ttx
    sta tx1
    lda ttx+1
    sta tx1+1
    lda dx2
    sta rt_dx
    lda dx2+1
    sta rt_dx+1
    lda dy2
    sta rt_dy
    lda dy2+1
    sta rt_dy+1
    jsr xdot
    lda ttx
    sta tx2
    lda ttx+1
    sta tx2+1
    ldy #4
    lda (wall_ptr),y
    sta ulen
    iny
    lda (wall_ptr),y
    sta seg_texoff      ; u0, staged (uacc set below)

    ; u endpoints (8.8): uacc = u0<<8, uend = (u0 + ulen)<<8
    lda #0
    sta uacc
    sta uend
    lda seg_texoff      ; u0
    sta uacc+1
    clc
    adc ulen
    sta uend+1

    ; --- near clip (same structure as M4) ---
    lda tz1
    sec
    sbc #<WALL_NEAR
    sta rt_acc
    lda tz1+1
    sbc #>WALL_NEAR
    sta rt_acc+1
    bmi @behind1
    lda tz2
    sec
    sbc #<WALL_NEAR
    lda tz2+1
    sbc #>WALL_NEAR
    bmi @clip2
    jmp @project
@behind1:
    lda tz2
    sec
    sbc #<WALL_NEAR
    lda tz2+1
    sbc #>WALL_NEAR
    bpl @clip1
    rts
@clip1:
    lda #<WALL_NEAR
    sec
    sbc tz1
    sta mul_a
    lda #>WALL_NEAR
    sbc tz1+1
    sta mul_a+1
    lda tz2
    sec
    sbc tz1
    sta rt_acc
    lda tz2+1
    sbc tz1+1
    sta rt_acc+1
    jsr clip_frac
    sta tclip
    lda tx2
    sec
    sbc tx1
    sta mul_a
    lda tx2+1
    sbc tx1+1
    sta mul_a+1
    lda tclip
    sta mul_b
    lda #0
    sta mul_b+1
    jsr mul16s8u
    lda tx1
    clc
    adc mul_r+1
    sta tx1
    lda tx1+1
    adc mul_r+2
    sta tx1+1
    lda #<WALL_NEAR
    sta tz1
    lda #>WALL_NEAR
    sta tz1+1
    lda ulen
    sta mul_a
    lda #0
    sta mul_a+1
    jsr mul16u          ; mul_b still = t
    lda uacc            ; uacc = u0<<8 + ulen*t
    clc
    adc mul_r
    sta uacc
    lda uacc+1
    adc mul_r+1
    sta uacc+1
    jmp @project
@clip2:
    lda #<WALL_NEAR
    sec
    sbc tz2
    sta mul_a
    lda #>WALL_NEAR
    sbc tz2+1
    sta mul_a+1
    lda tz1
    sec
    sbc tz2
    sta rt_acc
    lda tz1+1
    sbc tz2+1
    sta rt_acc+1
    jsr clip_frac
    sta tclip
    lda tx1
    sec
    sbc tx2
    sta mul_a
    lda tx1+1
    sbc tx2+1
    sta mul_a+1
    lda tclip
    sta mul_b
    lda #0
    sta mul_b+1
    jsr mul16s8u
    lda tx2
    clc
    adc mul_r+1
    sta tx2
    lda tx2+1
    adc mul_r+2
    sta tx2+1
    lda #<WALL_NEAR
    sta tz2
    lda #>WALL_NEAR
    sta tz2+1
    lda ulen
    sta mul_a
    lda #0
    sta mul_a+1
    jsr mul16u
    lda uend
    sec
    sbc mul_r
    sta uend
    lda uend+1
    sbc mul_r+1
    sta uend+1

@project:
    lda tz1
    sta ttz
    lda tz1+1
    sta ttz+1
    jsr rzh_lookup
    sta rzh1
    stx rzh1+1
    lda tz2
    sta ttz
    lda tz2+1
    sta ttz+1
    jsr rzh_lookup
    sta rzh2
    stx rzh2+1
    lda tx1
    sta mul_a
    lda tx1+1
    sta mul_a+1
    lda rzh1
    sta mul_b
    lda rzh1+1
    sta mul_b+1
    jsr mul16s16u
    lda mul_r+2
    and #7              ; 1/8-column fraction (the bits shift3_cx drops)
    sta frac1
    jsr shift3_cx
    clc
    adc #16
    sta cx1
    txa
    adc #0
    sta cx1+1
    lda tx2
    sta mul_a
    lda tx2+1
    sta mul_a+1
    lda rzh2
    sta mul_b
    lda rzh2+1
    sta mul_b+1
    jsr mul16s16u
    lda mul_r+2
    and #7
    sta frac2
    jsr shift3_cx
    clc
    adc #16
    sta cx2
    txa
    adc #0
    sta cx2+1
    ; reject: cx2 < cx1 (serves as the backface cull), off-screen.
    ; cx2 == cx1 with fractional width claims its single column — thin
    ; pillars and edge-on walls used to blink out of existence.
    lda cx2
    sec
    sbc cx1
    sta rt_acc
    lda cx2+1
    sbc cx1+1
    sta rt_acc+1
    bmi @rej
    ora rt_acc
    bne @nzs
    lda frac2
    cmp frac1
    beq @rej            ; no projected width at all
    bcc @rej            ; inverted: degenerate
    inc cx2
    bne :+
    inc cx2+1
:   lda #1
    sta rt_acc
    lda #0
    sta rt_acc+1
@nzs:
    lda cx2+1
    bmi @rej
    ora cx2
    beq @rej
    lda cx1+1
    bmi @spans
    bne @rej
    lda cx1
    cmp #32
    bcc @spans
@rej:
    rts

@spans:
    inc segs_drawn
    ; Exact projected occlusion before interpolation setup.  The angle gate
    ; rejects most hidden segs cheaply; this catches the remainder without
    ; paying for reciprocal/u/perspective steps that can never emit a column.
    lda cx1+1
    bpl @occ_left_visible
    lda #0
    sta col_l
    beq @occ_set_right
@occ_left_visible:
    lda cx1
    sta col_l
@occ_set_right:
    lda cx2+1
    bne @occ_right_edge
    lda cx2
    cmp #33
    bcc :+
@occ_right_edge:
    lda #32
:   sta col_r
    ldy col_l
@exact_occ:
    lda ceil_clip,y
    cmp floor_clip,y
    bcc @exact_open
    iny
    cpy col_r
    bcc @exact_occ
    rts
@exact_open:
    ldy #1
    lda (wall_ptr),y
    sta seg_vphase
    ldy #3
    lda (wall_ptr),y
    sta seg_vphase_l
    lda rt_acc+1
    beq :+
    lda #255
    bne :++
:   lda rt_acc
:   sta n0c
    ; rzstep = (rzh2 - rzh1) / n0c (sign-magnitude; recip_col is unsigned)
    lda rzh2
    sec
    sbc rzh1
    sta mul_a
    lda rzh2+1
    sbc rzh1+1
    sta mul_a+1
    sta tclip
    bpl :+
    lda #0
    sec
    sbc mul_a
    sta mul_a
    lda #0
    sbc mul_a+1
    sta mul_a+1
:   ldy n0c
    lda recip_col_lo,y
    sta mul_b
    lda recip_col_hi,y
    sta mul_b+1
    jsr mul16u
    lda tclip
    bpl :+
    sec
    lda #0
    sbc mul_r+2
    sta rzstep
    lda #0
    sbc mul_r+3
    sta rzstep+1
    jmp @ustep
:   lda mul_r+2
    sta rzstep
    lda mul_r+3
    sta rzstep+1
@ustep:
    lda uend
    sec
    sbc uacc
    sta mul_a
    lda uend+1
    sbc uacc+1
    sta mul_a+1
    ldy n0c
    lda recip_col_lo,y
    sta mul_b
    lda recip_col_hi,y
    sta mul_b+1
    jsr mul16u
    lda mul_r+2
    sta ustep
    lda mul_r+3
    sta ustep+1
    ; --- perspective u (kills affine swim): uoz = u*rzh/256 is linear in
    ; screen x, so an exact u = (uoz << 16) / rzh can re-anchor the affine
    ; interpolation every 8 drawn columns (resync_u). Only worth it on wide
    ; spans; skipped when the seg's u range wraps 256 texels (uoz would be
    ; a sawtooth, not a line).
    lda #0
    sta persp_on
    sta persp_cnt
    lda n0c
    cmp #9
    bcs :+
    jmp @npu            ; narrow span: affine drift is invisible
:   lda seg_texoff
    clc
    adc ulen
    bcc :+
    jmp @npu            ; u wraps mod 256 texels mid-seg
:   lda uacc
    sta mul_a
    lda uacc+1
    sta mul_a+1
    lda rzh1
    sta mul_b
    lda rzh1+1
    sta mul_b+1
    jsr mul16u
    lda mul_r+2         ; U1 = hi16(uacc * rzh1)
    sta uoz_acc
    lda mul_r+3
    sta uoz_acc+1
    lda uend
    sta mul_a
    lda uend+1
    sta mul_a+1
    lda rzh2
    sta mul_b
    lda rzh2+1
    sta mul_b+1
    jsr mul16u
    ; uoz_step = (U2 - U1) / n0c, sign-magnitude (recip_col is unsigned)
    lda mul_r+2
    sec
    sbc uoz_acc
    sta mul_a
    lda mul_r+3
    sbc uoz_acc+1
    sta mul_a+1
    sta tclip
    bpl :+
    sec
    lda #0
    sbc mul_a
    sta mul_a
    lda #0
    sbc mul_a+1
    sta mul_a+1
:   ldy n0c
    lda recip_col_lo,y
    sta mul_b
    lda recip_col_hi,y
    sta mul_b+1
    jsr mul16u
    lda tclip
    bpl :+
    sec
    lda #0
    sbc mul_r+2
    sta uoz_step
    lda #0
    sbc mul_r+3
    sta uoz_step+1
    jmp :++
:   lda mul_r+2
    sta uoz_step
    lda mul_r+3
    sta uoz_step+1
:   lda #1
    sta persp_on        ; persp_cnt = 0: first anchor at the first drawn col
@npu:
    ; left clip
    lda cx1+1
    bpl @clip_done
    lda #0
    sec
    sbc cx1
    sta rt_dx
    lda #0
    sbc cx1+1
    sta rt_dx+1
    lda rzstep
    sta mul_a
    lda rzstep+1
    sta mul_a+1
    lda rt_dx
    sta mul_b
    lda rt_dx+1
    sta mul_b+1
    jsr mul16s16u
    lda rzh1
    clc
    adc mul_r
    sta rzh1
    lda rzh1+1
    adc mul_r+1
    sta rzh1+1
    lda rt_dx
    sta mul_a
    lda rt_dx+1
    sta mul_a+1
    lda ustep
    sta mul_b
    lda ustep+1
    sta mul_b+1
    jsr mul16u
    lda uacc
    clc
    adc mul_r
    sta uacc
    lda uacc+1
    adc mul_r+1
    sta uacc+1
    lda persp_on
    beq @nclu
    lda uoz_step
    sta mul_a
    lda uoz_step+1
    sta mul_a+1
    lda rt_dx
    sta mul_b
    lda rt_dx+1
    sta mul_b+1
    jsr mul16s16u
    lda uoz_acc
    clc
    adc mul_r
    sta uoz_acc
    lda uoz_acc+1
    adc mul_r+1
    sta uoz_acc+1
@nclu:
@clip_done:
    ; Only surviving projected segments need texture pointers, sector heights,
    ; and lighting.  Keeping this after exact occlusion avoids setup for the
    ; many segs rejected by clipping or already-solid columns.
    ldy #6
    lda (wall_ptr),y    ; tex (mid/upper)
    ldx #0
    jsr set_texptrs
    ldy #7
    lda (wall_ptr),y    ; tex_low
    ldx #4
    jsr set_texptrs
    ldy #8
    lda (wall_ptr),y    ; front sector: heights relative to eye (signed)
    tax
.ifdef E1M1
    lda SECTOR_CEIL_RT,x
.else
    lda sec_ceil,x
.endif
    sec
    sbc eye_h
    sta seg_hc
    lda eye_h
    sec
    sbc sec_floor,x
    sta seg_hf
    lda sec_light,x
    sta seg_light
    tay
    lda fl_thr_tbl,y    ; floor rows below this are dark (row-distance fade)
    sta fl_thr
    ldy #9
    lda (wall_ptr),y
    sta seg_back
    ldx #0
    cmp #$FF
    beq :+
    tay
.ifdef E1M1
    lda SECTOR_CEIL_RT,y
.else
    lda sec_ceil,y
.endif
    sec
    sbc eye_h
    sta seg_bhc
    lda eye_h
    sec
    sbc sec_floor,y
    sta seg_bhf
    ldx #1
:   stx two_sided

    ; --- height interpolators (from the already-advanced rzh1) ---
    lda seg_hc
    jsr mul_h_rzh
    sta ytop_acc
    stx ytop_acc+1
    lda seg_hc
    jsr mul_h_step
    sta ytop_step
    stx ytop_step+1
    lda seg_hf
    jsr mul_h_rzh
    sta ybot_acc
    stx ybot_acc+1
    lda seg_hf
    jsr mul_h_step
    sta ybot_step
    stx ybot_step+1
    lda two_sided
    beq @cols
    lda seg_bhc
    jsr mul_h_rzh
    sta btop_acc
    stx btop_acc+1
    lda seg_bhc
    jsr mul_h_step
    sta btop_step
    stx btop_step+1
    lda seg_bhf
    jsr mul_h_rzh
    sta bbot_acc
    stx bbot_acc+1
    lda seg_bhf
    jsr mul_h_step
    sta bbot_step
    stx bbot_step+1

@cols:
    lda col_l
    sta cur_col
@cl:
    lda cur_col
    cmp col_r
    bcc @colbody
    rts
@colbody:
    ldy cur_col
    lda ceil_clip,y
    cmp floor_clip,y
    bcc :+
    jmp @advance        ; column already solid
:
    ; perspective-u: anchor due? (chunk_u keeps u continuous through
    ; exact anchors — no snapping)
    lda persp_on
    beq :+
    lda persp_cnt
    bne :+
    jsr chunk_u
:   ; light (palette bit 6): dark when 2*sector + light2 >= 6; the
    ; half-band below the threshold (== 5) dissolves by column parity —
    ; a hard 2-level step read as a vertical band across long walls
    lda rzh1
    asl
    lda rzh1+1
    rol
    tay
    lda light2_tbl,y
    clc
    adc seg_light
    adc seg_light
    cmp #6
    bcs @ldark
    cmp #5
    bne @lbright
    lda uacc+1
    and #8              ; 8-texel parity: anchored to the wall surface, so
    bne @lbright        ; the dissolve does not shimmer when the camera moves
@ldark:
    lda #$40
    bne @lset
@lbright:
    lda #0
@lset:
    sta emit_lt
    ; sub-tile pixel remainders of the front boundaries (acc bits 4-6)
    lda ytop_acc
    and #$70
    lsr
    lsr
    lsr
    lsr
    sta ek_top
    lda ybot_acc
    and #$70
    lsr
    lsr
    lsr
    lsr
    sta ek_bot
    ; v offsets (signed acc>>7, clamped so row math stays in 8-bit range)
    lda ytop_acc
    asl
    lda ytop_acc+1
    rol
    jsr clamp60
    sta vtop
    lda ybot_acc
    asl
    lda ybot_acc+1
    rol
    jsr clamp60
    sta vbot
    lda two_sided
    beq :+
    lda btop_acc
    asl
    lda btop_acc+1
    rol
    jsr clamp60
    sta vbtop
    lda bbot_acc
    asl
    lda bbot_acc+1
    rol
    jsr clamp60
    sta vbbot
:   jsr emit_column_m5
@advance:
    lda rzh1
    clc
    adc rzstep
    sta rzh1
    lda rzh1+1
    adc rzstep+1
    sta rzh1+1
    lda uacc
    clc
    adc ustep
    sta uacc
    lda uacc+1
    adc ustep+1
    sta uacc+1
    lda persp_on
    beq :+
    lda uoz_acc
    clc
    adc uoz_step
    sta uoz_acc
    lda uoz_acc+1
    adc uoz_step+1
    sta uoz_acc+1
    lda persp_cnt
    beq :+
    dec persp_cnt
:   lda ytop_acc
    clc
    adc ytop_step
    sta ytop_acc
    lda ytop_acc+1
    adc ytop_step+1
    sta ytop_acc+1
    lda ybot_acc
    clc
    adc ybot_step
    sta ybot_acc
    lda ybot_acc+1
    adc ybot_step+1
    sta ybot_acc+1
    lda two_sided
    beq :+
    lda btop_acc
    clc
    adc btop_step
    sta btop_acc
    lda btop_acc+1
    adc btop_step+1
    sta btop_acc+1
    lda bbot_acc
    clc
    adc bbot_step
    sta bbot_acc
    lda bbot_acc+1
    adc bbot_step+1
    sta bbot_acc+1
:   inc cur_col
    jmp @cl

; ---------------------------------------------------------------------------
; emit_column_m5: draw one screen column of this seg into the compose buffer.
; ---------------------------------------------------------------------------
emit_column_m5:
    inc cols_drawn
    ldy cur_col
    lda ceil_clip,y
    sta ceil0
    lda floor_clip,y
    sta floor0
    lda cur_col
    ora rf_backoff
    tay
    lda colbase_lo,y
    sta dst_nt
    lda colbase_hi,y
    sta dst_nt+1
    lda dst_nt
    clc
    adc #$80
    sta dst_ex
    lda dst_nt+1
    adc #$02
    sta dst_ex+1
    ; slice pointers + ramp default to the mid/upper texture
    lda sl_tp
    sta cur_tp
    lda sl_tp+1
    sta cur_tp+1
    lda sl_bp
    sta cur_bp
    lda sl_bp+1
    sta cur_bp+1
    lda sl_mc
    sta cur_mc
    lda sl_vp
    sta cur_vp
    lda seg_vphase
    sta cur_phase
    lda sl_tex
    sta cur_tex
    lda #0
    sta ew_top
    sta ew_bot
    lda emit_lt
    sta edge_top_ex
    ; t = clamp(10 - vtop, [0,20], then [ceil0, floor0])   (vtop signed)
    lda #10
    sec
    sbc vtop
    jsr clamp_row
    cmp ceil0
    bcs :+
    lda ceil0
:   cmp floor0
    bcc :+
    lda floor0
:   sta t_row
    ; b = clamp(10 + vbot, ...)
    lda vbot
    clc
    adc #10
    jsr clamp_row
    cmp ceil0
    bcs :+
    lda ceil0
:   cmp floor0
    bcc :+
    lda floor0
:   sta b_row
    ; ceiling [ceil0, t)
    ldy ceil0
@ce:
    cpy t_row
    bcs @cedone
    lda #CEIL_NT
    sta (dst_nt),y
    lda #CEIL_EX
    sta (dst_ex),y
    iny
    bne @ce
@cedone:
    lda two_sided
    beq @solid
    jmp @portal
@solid:
    ; wall [t, b): class from span = clamp(vtop + vbot, 1..20)  (signed sum)
    lda vtop
    clc
    adc vbot
    beq @sliver
    bmi @swdone
    jsr set_period_slice
    lda exbyte
    sta edge_top_ex
    lda vtop
    sec
    sbc #10
    sta eob
    lda t_row
    sta ers
    lda b_row
    sta ere
    jsr emit_wall_run
    lda #1
    sta ew_top
    sta ew_bot
    bne @swdone
@sliver:
    ; zero-row wall: the boundary fractions still hold up to 7px of wall
    ; on each side of the row line — arm emit_edges instead of vanishing
    ; (distant walls used to pop in/out of existence here)
    lda #0
    jsr set_slice       ; retain the texture's baked warm/cool ramp
    lda exbyte
    sta edge_top_ex
    lda #1
    sta ew_top
    sta ew_bot
@swdone:
    ; floor [b, floor0)
    ldy b_row
@fl:
    cpy floor0
    bcs @fldone
    lda #FLOOR_NT
    sta (dst_nt),y
    ldx #0              ; bright
    cpy fl_thr
    bcs :++
    ldx #$40            ; rows near the horizon are far -> dark
    iny
    cpy fl_thr
    dey
    bne :++
    lda cur_col         ; boundary row: dither by column parity
    lsr
    bcc :++
:   ldx #0
:   txa
    ora #FLOOR_EX
    sta (dst_ex),y
    iny
    bne @fl
@fldone:
    jsr emit_edges
    ldy cur_col
    lda #VIEW_ROWS
    sta ceil_clip,y
    lda #0
    sta floor_clip,y
    inc solid_cnt
    rts
@portal:
    ; bt = clamp(10 - vbtop, [0,20], then [t, b])   (vbtop signed)
    lda #10
    sec
    sbc vbtop
    jsr clamp_row
    cmp t_row
    bcs :+
    lda t_row
:   cmp b_row
    bcc :+
    lda b_row
:   sta bt_row
    ; bb = clamp(10 + vbbot, [0,20], then [bt, b])
    lda vbbot
    clc
    adc #10
    jsr clamp_row
    cmp bt_row
    bcs :+
    lda bt_row
:   cmp b_row
    bcc :+
    lda b_row
:   sta bb_row
    ; upper wall [t, bt): span_u = vtop - vbtop (signed)
    lda vtop
    sec
    sbc vbtop
    bpl :+
    jmp @noupper
:
    beq @upsliver
    jsr set_period_slice
    lda exbyte
    sta edge_top_ex
    lda vtop
    sec
    sbc #10
    sta eob
    lda t_row
    sta ers
    lda bt_row
    sta ere
    jsr emit_wall_run
    lda #1
    sta ew_top
    bne @noupper
@upsliver:
    ; Front/back ceilings share a tile row.  Encode both fractions so the
    ; wall strip stays at its true interior position instead of a tile edge.
    lda ytop_acc
    sec
    sbc btop_acc
    sta mtmp
    lda ytop_acc+1
    sbc btop_acc+1
    bmi @noupper
    bne @upencode
    lda mtmp
    beq @noupper
@upencode:
    lda btop_acc
    and #$70
    .repeat 4
    lsr
    .endrepeat
    sta mtmp+1          ; back fraction
    lda ek_top
    sta mtmp+2          ; front fraction
    cmp mtmp+1
    bne @upkey
    cmp #7              ; nonzero sub-pixel difference: retain one pixel
    bcs @upwrap
    inc mtmp+2
    bne @upkey
@upwrap:
    lda #PORTAL_TOP_WRAP
    sta edge_top_tile
    bne @upselected
@upkey:
    lda mtmp+2
    asl
    asl
    asl
    ora mtmp+1
    clc
    adc #PORTAL_TOP_BASE
    sta edge_top_tile
@upselected:
    lda #0              ; zero-row upper wall: preserve its texture ramp
    jsr set_slice
    lda exbyte
    sta edge_top_ex
    lda #2              ; flat a/b edge shape from the portal-part thickness
    sta ew_top
@noupper:
    ; lower wall [bb, b): span_l = vbot - vbbot (signed); off = y - (10+vbbot)
    lda vbot
    sec
    sbc vbbot
    bpl :+
    jmp @nolower
:
    beq @losliver
    lda sl_tp_l         ; lower wall uses its own texture + ramp
    sta cur_tp
    lda sl_tp_l+1
    sta cur_tp+1
    lda sl_bp_l
    sta cur_bp
    lda sl_bp_l+1
    sta cur_bp+1
    lda sl_mc+4
    sta cur_mc
    lda sl_vp_l
    sta cur_vp
    lda seg_vphase_l
    sta cur_phase
    lda sl_tex_l
    sta cur_tex
    jsr set_period_slice
    lda vbbot
    clc
    adc #10
    eor #$FF
    clc
    adc #1
    sta eob
    lda bb_row
    sta ers
    lda b_row
    sta ere
    jsr emit_wall_run
    lda #1
    sta ew_bot
    bne @nolower
@losliver:
    ; Front/back floors share a tile row.  Encode both fractions so the step
    ; occupies its true interior band and retains portal pixels above it.
    lda ybot_acc
    sec
    sbc bbot_acc
    sta mtmp
    lda ybot_acc+1
    sbc bbot_acc+1
    bmi @nolower
    bne @loencode
    lda mtmp
    beq @nolower
@loencode:
    lda bbot_acc
    and #$70
    .repeat 4
    lsr
    .endrepeat
    sta mtmp+1
    lda ek_bot
    sta mtmp+2
    cmp mtmp+1
    bne @lokey
    cmp #7
    bcs @lowrap
    inc mtmp+2
    bne @lokey
@lowrap:
    lda #PORTAL_BOT_WRAP
    sta edge_bot_tile
    bne @loselected
@lokey:
    lda mtmp+2
    asl
    asl
    asl
    ora mtmp+1
    clc
    adc #PORTAL_BOT_BASE
    sta edge_bot_tile
@loselected:
    lda sl_tp_l         ; select the lower texture's ramp for the step pixels
    sta cur_tp
    lda sl_tp_l+1
    sta cur_tp+1
    lda sl_bp_l
    sta cur_bp
    lda sl_bp_l+1
    sta cur_bp+1
    lda sl_mc+4
    sta cur_mc
    lda sl_vp_l
    sta cur_vp
    lda seg_vphase_l
    sta cur_phase
    lda #0
    jsr set_slice
    lda #2
    sta ew_bot
@nolower:
    ; floor [b, floor0)
    ldy b_row
@pfl:
    cpy floor0
    bcs @pfldone
    lda #FLOOR_NT
    sta (dst_nt),y
    ldx #0              ; bright
    cpy fl_thr
    bcs :++
    ldx #$40            ; rows near the horizon are far -> dark
    iny
    cpy fl_thr
    dey
    bne :++
    lda cur_col         ; boundary row: dither by column parity
    lsr
    bcc :++
:   ldx #0
:   txa
    ora #FLOOR_EX
    sta (dst_ex),y
    iny
    bne @pfl
@pfldone:
    jsr emit_edges
    ; narrow the clip window to the portal opening
    ldy cur_col
    lda bt_row
    sta ceil_clip,y
    lda bb_row
    sta floor_clip,y
    cmp bt_row
    bne :+
    inc solid_cnt       ; portal closed on this column
:   rts

set_period_slice:
    ; Select scale from one projected native texture period, not geometric
    ; wall-part height.  This keeps texel scale stable and allows repetition.
    lda cur_vp
    sta mul_a
    lda rzh1
    sta mul_b
    lda rzh1+1
    sta mul_b+1
    jsr mul8u16u
    lda mul_r+1
    asl
    lda mul_r+2
    rol                 ; projected texture period in screen tile rows
    bne :+
    lda #1
:   ldx #0
@period_reduce:
    cmp #21
    bcc @period_class
    clc
    adc #1
    lsr
    inx
    bne @period_reduce
@period_class:
    stx vshift
    tax
    lda span_class,x
    jsr set_slice
    lda cur_phase       ; normalized 0..255 -> selected baked row
    sta MMC5_MULT_A
    lda eclh
    sta MMC5_MULT_B
    lda MMC5_MULT_A
    sta mtmp
    lda MMC5_MULT_B
    sta mtmp+1
    sta phase_row
    jsr select_vhalf
    rts

select_vhalf:
    ; Sparse 4-pixel shifted variants exist for selected 12/14-row slices.
    lda eclh
    cmp #12
    beq @class12
    cmp #14
    beq :+
    rts
:
    lda cur_tex
    clc
    adc #16
    bne @pointer
@class12:
    lda cur_tex
@pointer:
    tay
    lda vhalf_ptr_lo,y
    sta tptr
    lda vhalf_ptr_hi,y
    beq @no
    sta tptr+1

    ; Static map phase selects the whole/half row.  Projected boundary
    ; fractions are silhouette geometry and must not make texture origins
    ; creep while approaching a wall.
    lda mtmp
    clc
    adc #64
    sta mtmp
    lda mtmp+1
    adc #0
    sta mtmp+1
    cmp eclh
    bcc @normalized
    sbc eclh
    sta mtmp+1
@normalized:
    lda mtmp
    asl
    lda mtmp+1
    rol
    sta mtmp+2
    lsr
    sta phase_row
    lda mtmp+2
    and #1
    beq @no
    lda slice_phase
    asl
    tay
    lda (tptr),y
    sta tile_base
    iny
    lda (tptr),y
    ora emit_lt
    sta exbyte
@no:
    rts

set_slice:              ; A = class index -> tile_base, eclh, exbyte
    cmp cur_mc
    bcc :+
    beq :+
    lda cur_mc
:
    tax                 ; reads through cur_tp/cur_bp for the selected texture
    lda class_h_tbl,x
    sta eclh
    ; phase = (u >> class_pshift) & class_pmask — per-class isotropic
    ; texel widths (CLASS_TW in tilegen): 4..64 texels per column
    lda uacc+1
    ldy class_pshift,x
@sh:
    lsr
    dey
    bne @sh
    and class_pmask,x
    sta slice_phase
    clc
    adc class_base_tbl,x
    tay
    lda (cur_tp),y
    sta tile_base
    lda (cur_bp),y      ; bank bits 0-5 + per-slice ramp in bit 7
    ora emit_lt
    sta exbyte
    rts

; ---------------------------------------------------------------------------
; emit_edges: pixel-precision silhouettes. When a wall run was drawn at the
; front ceiling/floor boundary and the boundary has a sub-tile remainder,
; overwrite the adjacent flat row with a shared edge tile (ceiling color
; above / flat wall color below, or wall above / floor color below). Skipped
; when the boundary was clipped (raw row != clamped row) or out of window.
; ---------------------------------------------------------------------------
emit_edges:
.ifdef E1M1
    ; Sloped silhouette tiles (EDGE_BANK): boundary ramps from this
    ; column's fraction (a = ek) to the next column's (b, from acc+step,
    ; clamped 7/0 when the boundary exits the row) -- kills the 8px
    ; stairstep on sloped wall tops/bottoms. Tile = a*8+b (+64 bottom).
    lda ew_top
    beq @net
    lda #10
    sec
    sbc vtop
    cmp t_row
    bne @net            ; boundary was clip-adjusted -> no edge
    lda t_row
    cmp ceil0
    beq @net            ; no room above inside the clip window
    bcc @net
    lda ew_top
    cmp #2
    bne :+
    ldy t_row
    dey
    lda edge_top_tile
    sta (dst_nt),y
    lda edge_top_ex
    and #$C0
    ora #FLAT_BANK
    sta (dst_ex),y
    jmp @net
:
    lda ytop_acc
    clc
    adc ytop_step
    sta mtmp
    lda ytop_acc+1
    adc ytop_step+1
    sta mtmp+1
    lda mtmp
    asl
    lda mtmp+1
    rol                 ; A = next column's boundary row (acc2 >> 7)
    sta mtmp+2
    lda ytop_acc
    asl
    lda ytop_acc+1
    rol                 ; A = this column's boundary row
    cmp mtmp+2
    beq @tsame          ; equality is wrap-safe; direction comes from the
    lda ytop_step+1     ; step sign (unsigned row compare mis-clamped at
    bmi @tfell          ; the horizon where the accumulator crosses zero)
    lda #7              ; boundary rises out of this row
    bne @tb
@tfell:
    lda #0
    beq @tb
@tsame:
    lda mtmp
    lsr
    lsr
    lsr
    lsr
    and #7
@tb:
    sta mtmp+3          ; b
    ora ek_top
    beq @net            ; flat empty boundary
    lda ek_top
    asl
    asl
    asl
    ora mtmp+3
    ldy t_row
    dey
    sta (dst_nt),y
    lda edge_top_ex
    and #$C0
    ora #EDGE_BANK
    sta (dst_ex),y
@net:
    lda ew_bot
    beq @neb
    lda vbot
    clc
    adc #10
    cmp b_row
    bne @neb
    lda b_row
    cmp floor0
    bcs @neb
    lda ew_bot
    cmp #2
    bne :+
    ldy b_row
    lda edge_bot_tile
    sta (dst_nt),y
    lda exbyte
    and #$C0
    ora #FLAT_BANK
    sta (dst_ex),y
    jmp @neb
:
    lda ybot_acc
    clc
    adc ybot_step
    sta mtmp
    lda ybot_acc+1
    adc ybot_step+1
    sta mtmp+1
    lda mtmp
    asl
    lda mtmp+1
    rol
    sta mtmp+2
    lda ybot_acc
    asl
    lda ybot_acc+1
    rol
    cmp mtmp+2
    beq @bsame
    lda ybot_step+1     ; step sign, wrap-safe (see top boundary)
    bmi @brise
    lda #7              ; boundary drops below this row -> full wall
    bne @bb
@brise:
    lda #0
    beq @bb
@bsame:
    lda mtmp
    lsr
    lsr
    lsr
    lsr
    and #7
@bb:
    sta mtmp+3
    ora ek_bot
    beq @neb
    lda ek_bot
    asl
    asl
    asl
    ora mtmp+3
    clc
    adc #64             ; bottom-boundary tile set
    ldy b_row
    sta (dst_nt),y
    lda exbyte           ; prioritize the small wall feature's material ramp
    and #$C0
    ora #EDGE_BANK
    sta (dst_ex),y
@neb:
.else
    lda ew_top
    beq @net
    lda #10
    sec
    sbc vtop
    cmp t_row
    bne @net            ; boundary was clip-adjusted -> no edge
    lda t_row
    cmp ceil0
    beq @net            ; no room above inside the clip window
    bcc @net
    lda ew_top
    cmp #2
    bne :+
    ldy t_row
    dey
    lda edge_top_tile
    sta (dst_nt),y
    lda edge_top_ex
    and #$C0
    ora #FLAT_BANK
    sta (dst_ex),y
    jmp @net
:   lda ek_top
    beq @net
    lda t_row
    sec
    sbc #1
    tay
    lda #EDGE_TOP_BASE
    clc
    adc ek_top
    sta (dst_nt),y
    lda edge_top_ex
    and #$C0
    ora #FLAT_BANK
    sta (dst_ex),y
@net:
    lda ew_bot
    beq @neb
    lda vbot
    clc
    adc #10
    cmp b_row
    bne @neb
    lda b_row
    cmp floor0
    bcs @neb
    lda ew_bot
    cmp #2
    bne :+
    ldy b_row
    lda edge_bot_tile
    sta (dst_nt),y
    lda exbyte
    and #$C0
    ora #FLAT_BANK
    sta (dst_ex),y
    jmp @neb
:   lda ek_bot
    beq @neb
    lda b_row
    tay
    lda #EDGE_BOT_BASE
    clc
    adc ek_bot
    sta (dst_nt),y
    lda exbyte
    and #$C0
    ora #FLAT_BANK
    sta (dst_ex),y
@neb:
.endif
    rts

emit_wall_run:          ; rows [ers, ere), wrapping one native texture period
    ldy ers
@wrap_row:
    cpy ere
    bcs @wrap_done
    tya
    clc
    adc eob
    bpl :+
    lda #0
:   ldx vshift
    beq :++
:   lsr
    dex
    bne :-
:   clc
    adc phase_row
@wrap_period:
    cmp eclh
    bcc :+
    sbc eclh            ; carry is set by cmp
    jmp @wrap_period
:   clc
    adc tile_base
    sta (dst_nt),y
    lda exbyte
    sta (dst_ex),y
    iny
    jmp @wrap_row
@wrap_done:
    rts

light_sh:
    .byte $00, $40, $80, $C0

; sector light -> first floor row at light-0 distance (z = 656/(row-10)
; through the 96/160/288 light bands; light-3 sectors are dark throughout)
fl_thr_tbl:
    .byte 13, 15, 17, 32

class_h_tbl:
    .byte 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 16, 20

; per-class phase extraction (texel width tw: phases = 64/tw,
; shift = log2(tw) - 2 + 3? no: phase = (uacc16 >> (8 + log2(tw))) via
; uacc+1 >> (log2(tw))... values below are lsr counts on uacc+1 hi byte)
class_pshift:           ; uacc+1 >> n (tw=4:2, 8:3, 16:4, 32:5, 64:5)
    .byte 5, 5, 5, 4, 4, 4, 4, 3, 3, 3, 2, 2, 2, 2
class_pmask:            ; phases-1
    .byte 0, 1, 1, 3, 3, 3, 3, 7, 7, 7, 15, 15, 15, 15
class_base_tbl:         ; cumulative phase counts per class
    .byte 0, 1, 3, 5, 9, 13, 17, 21, 29
    .byte 37, 45, 61, 77, 93

span_class:             ; screen-row span -> smallest class >= span
    .byte 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 10, 11, 11, 12, 12, 13, 13, 13, 13

; compose-buffer column base addresses: [buf*32 + col] -> NT shadow + col*20
colbase_lo:
    .repeat 32, c
    .byte <(BUFA_NT + c*VIEW_ROWS)
    .endrepeat
    .repeat 32, c
    .byte <(BUFB_NT + c*VIEW_ROWS)
    .endrepeat
colbase_hi:
    .repeat 32, c
    .byte >(BUFA_NT + c*VIEW_ROWS)
    .endrepeat
    .repeat 32, c
    .byte >(BUFB_NT + c*VIEW_ROWS)
    .endrepeat
