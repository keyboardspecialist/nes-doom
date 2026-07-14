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

.import mul16u, mul16s, atan2_hi, render_bsp, find_sector
.import sin_lo, sin_hi, recipf_lo, recipf_hi
.import recip_col_lo, recip_col_hi, light2_tbl, angcol_tbl
.import slice_tile, slice_bank, tex_base_lo, tex_base_hi
.import map_verts, sec_floor, sec_ceil, sec_light
.import ceil_clip, floor_clip
.import PLAYER_PX, PLAYER_PY, PLAYER_ANG, EYE_REL
.ifdef E1M1
.import sec_pal
.endif
.import PX_MIN_H, PX_MAX_H, PY_MIN_H, PY_MAX_H
.import REJECT_ROWB, reject_tbl
.export render_frame, init_camera, do_seg

.segment "BSS"
vang:   .res 256            ; per-vertex view angle (BAM hi-byte), per pass
vdone:  .res 32             ; bitmap: angle computed this pass
vnear:  .res 32             ; bitmap: vertex too close for a reliable angle

NEAR    = 256               ; s11.4: 16 world units
TURN    = 512               ; BAM per pass (~2.8 deg)
CEIL_NT  = 4                ; blank tile -> the backdrop IS the ceiling color
CEIL_EX  = FLAT_BANK | $80  ; palette bits irrelevant for a blank tile
FLOOR_NT = 2
FLOOR_EX = FLAT_BANK        ; ramp A; dark bit added below fl_thr (row fade)
EDGE_TOP_BASE = 4           ; tiles 5-11: k wall rows below ceiling color
EDGE_BOT_BASE = 11          ; tiles 12-18: k wall rows above floor color

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
    rts

render_frame:
    lda frame_cnt
    sta rf_t0
    lda #0
    sta cols_drawn
    sta segs_drawn
    jsr read_input
    jsr update_cam
    jsr find_sector     ; -> cam_sec; eye follows the camera's sector floor
    ldx cam_sec
    lda sec_floor,x
    clc
    adc #<EYE_REL
    sta eye_h
.ifdef E1M1
    ; pal_ptr = sec_pal + cam_sec*16: the NMI loads this sector's palette
    ; set every frame during vblank (rooms get their own hue ramps)
    lda #0
    sta pal_ptr+1
    lda cam_sec
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
.endif
    ; rj_ptr = reject_tbl + cam_sec * REJECT_ROWB (tiny per-frame multiply)
    lda #0
    ldx cam_sec
    beq :++
:   clc
    adc #<REJECT_ROWB
    dex
    bne :-
:   clc
    adc #<reject_tbl
    sta rj_ptr
    lda #>reject_tbl
    adc #0
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
    ; invalidate the per-vertex angle cache (camera moved)
    ldy #31
    lda #0
:   sta vdone,y
    sta vnear,y
    dey
    bpl :-
    jsr render_bsp
    lda frame_cnt
    sec
    sbc rf_t0
    sta pass_frames
    rts

read_input:
    lda #1
    sta $4016
    lda #0
    sta $4016
    ldx #8
@l: lda $4016
    lsr
    ror joy1
    dex
    bne @l
    rts

update_cam:
    lda joy1
    and #$40            ; Left: rotate CCW
    beq :+
    lda pang
    clc
    adc #<TURN
    sta pang
    lda pang+1
    adc #>TURN
    sta pang+1
:   lda joy1
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
    lda joy1
    and #$10            ; Up: forward (step = view dir / 2 = 8 units)
    beq :+
    jsr step_forward
:   lda joy1
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

step_forward:
    jsr half_view
    lda px
    clc
    adc rt_dx
    sta px
    lda px+1
    adc rt_dx+1
    sta px+1
    lda py
    clc
    adc rt_dy
    sta py
    lda py+1
    adc rt_dy+1
    sta py+1
    rts

step_back:
    jsr half_view
    lda px
    sec
    sbc rt_dx
    sta px
    lda px+1
    sbc rt_dx+1
    sta px+1
    lda py
    sec
    sbc rt_dy
    sta py
    lda py+1
    sbc rt_dy+1
    sta py+1
    rts

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
    jsr mul16s
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
    jsr mul16s
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
    jsr mul16s
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
    jsr mul16s
    lda rt_acc
    sec
    sbc mul_r+1
    sta ttx
    lda rt_acc+1
    sbc mul_r+2
    sta ttx+1
    rts

; rzh = recipf[clamp(tz>>4, 0..1023)] (table spans 4 pages -> pointer access)
rzh_lookup:
    lda ttz
    sta tptr
    lda ttz+1
    sta tptr+1
    .repeat 4
    lsr tptr+1
    ror tptr
    .endrepeat
    lda tptr+1
    cmp #4
    bcc :+
    lda #<512
    ldx #>512
    rts
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
    rts

; near-clip fraction: A = clamp255((NEAR - tz_behind) * recipf[dz>>4] >> 15)
clip_frac:
    lda rt_acc
    sta ttz
    lda rt_acc+1
    sta ttz+1
    jsr rzh_lookup
    sta mul_b
    stx mul_b+1
    jsr mul16u
    lda mul_r+3
    bne @max
    lda mul_r+2
    bmi @max
    lda mul_r+1
    asl
    lda mul_r+2
    rol
    rts
@max:
    lda #255
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
    ldx #0
    ora #0              ; N from A (ldx clobbered it)
    bpl :+
    dex                 ; sign-extend
:   stx mul_a+1
    lda rzh1
    sta mul_b
    lda rzh1+1
    sta mul_b+1
    jsr mul16s
    lda mul_r+1
    ldx mul_r+2
    rts

mul_h_step:             ; A = h (SIGNED) -> A/X = (h * rzstep) >> 8, signed
    sta mul_a
    ldx #0
    ora #0              ; N from A (ldx clobbered it)
    bpl :+
    dex
:   stx mul_a+1
    lda rzstep
    sta mul_b
    lda rzstep+1
    sta mul_b+1
    jsr mul16s
    lda mul_r+1
    ldx mul_r+2
    rts

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

; fetch_vertex: Y = record offset of a 16-bit vertex index -> wx/wy
fetch_vertex:
    lda (wall_ptr),y
    sta tptr
    iny
    lda (wall_ptr),y
    sta tptr+1
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
    rts

; set slice-LUT base pointers for a texture slot in A; X selects which pair
; (0 = mid/upper -> sl_tp/sl_bp, 4 = lower -> sl_tp_l/sl_bp_l).
; (The palette ramp bit rides bit 7 of each slice_bank LUT byte.)
set_texptrs:
    tay
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
; vert_angle: X = vertex index (maps are capped at 256 vertices). Returns
; A = view angle of the vertex (BAM hi-byte) with C clear, or C set when the
; vertex is too close for a reliable atan. Cached per pass in vang/vdone/
; vnear so shared seg endpoints cost one atan per frame.
; ---------------------------------------------------------------------------
vert_angle:
    stx vtmp
    txa
    and #7
    tay
    lda va_bit,y
    sta vmask
    txa
    lsr
    lsr
    lsr
    tay
    lda vdone,y
    and vmask
    beq @compute
    lda vnear,y
    and vmask
    bne @near
    ldx vtmp
    lda vang,x
    clc
    rts
@near:
    sec
    rts
@compute:
    lda vdone,y
    ora vmask
    sta vdone,y
    ; rt_dx/rt_dy = vertex - camera (map_verts is 4-byte records)
    lda #0
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
    jsr atan2_hi
    bcs @toonear
    ldx vtmp
    sta vang,x
    clc
    rts
@toonear:
    lda vtmp
    lsr
    lsr
    lsr
    tay
    lda vnear,y
    ora vmask
    sta vnear,y
    sec
    rts

va_bit:
    .byte $01, $02, $04, $08, $10, $20, $40, $80

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
; v1 v2 (vertex indices), ulen (texels), u0, tex, tex_low, front, back
;
; Angle gate (Doom's R_AddLine): cached per-vertex angles decide backface /
; off-frustum / fully-occluded before any transform math. Only segs that
; survive (or whose angles are unreliable) touch the multiplier.
; ---------------------------------------------------------------------------
do_seg:
    ldy #0
    lda (wall_ptr),y
    tax
    jsr vert_angle
    bcs @gf
    sta seg_a1
    ldy #2
    lda (wall_ptr),y
    tax
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
    sbc #<NEAR
    lda tz1+1
    sbc #>NEAR
    bpl @infront
    lda tz2
    sec
    sbc #<NEAR
    lda tz2+1
    sbc #>NEAR
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
    iny
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
    lda sec_ceil,x
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
    lda sec_ceil,y
    sec
    sbc eye_h
    sta seg_bhc
    lda eye_h
    sec
    sbc sec_floor,y
    sta seg_bhf
    ldx #1
:   stx two_sided

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
    sbc #<NEAR
    sta rt_acc
    lda tz1+1
    sbc #>NEAR
    sta rt_acc+1
    bmi @behind1
    lda tz2
    sec
    sbc #<NEAR
    lda tz2+1
    sbc #>NEAR
    bmi @clip2
    jmp @project
@behind1:
    lda tz2
    sec
    sbc #<NEAR
    lda tz2+1
    sbc #>NEAR
    bpl @clip1
    rts
@clip1:
    lda #<NEAR
    sec
    sbc tz1
    sta mul_a
    lda #>NEAR
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
    jsr mul16s
    lda tx1
    clc
    adc mul_r+1
    sta tx1
    lda tx1+1
    adc mul_r+2
    sta tx1+1
    lda #<NEAR
    sta tz1
    lda #>NEAR
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
    lda #<NEAR
    sec
    sbc tz2
    sta mul_a
    lda #>NEAR
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
    jsr mul16s
    lda tx2
    clc
    adc mul_r+1
    sta tx2
    lda tx2+1
    adc mul_r+2
    sta tx2+1
    lda #<NEAR
    sta tz2
    lda #>NEAR
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
    jsr mul16s
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
    jsr mul16s
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
    bpl @noadv
    lda #0
    sec
    sbc cx1
    sta rt_dx
    lda #0
    sbc cx1+1
    sta rt_dx+1
    lda rt_dx
    sta mul_a
    lda rt_dx+1
    sta mul_a+1
    lda rzstep
    sta mul_b
    lda rzstep+1
    sta mul_b+1
    jsr mul16s
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
    lda rt_dx
    sta mul_a
    lda rt_dx+1
    sta mul_a+1
    lda uoz_step
    sta mul_b
    lda uoz_step+1
    sta mul_b+1
    jsr mul16s
    lda uoz_acc
    clc
    adc mul_r
    sta uoz_acc
    lda uoz_acc+1
    adc mul_r+1
    sta uoz_acc+1
@nclu:
    lda #0
    sta col_l
    beq @setr
@noadv:
    lda cx1
    sta col_l
@setr:
    lda cx2+1
    bne @r32
    lda cx2
    cmp #33
    bcc :+
@r32:
    lda #32
:   sta col_r
    ; fully-occluded seg? (every column in [col_l, col_r) already solid)
    ldy col_l
@occ:
    lda ceil_clip,y
    cmp floor_clip,y
    bcc @open
    iny
    cpy col_r
    bcc @occ
    rts
@open:

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
    lda #0
    sta ew_top
    sta ew_bot
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
    ldx #0
:   cmp #21             ; spans > 20 rows: halve until a class fits and
    bcc :+              ; pixel-double vertically on emit (vshift) — the
    lsr                 ; texture covers the whole wall instead of smearing
    inx                 ; its last row
    jmp :-
:   stx vshift
    tax
    lda span_class,x
    jsr set_slice
    lda vtop
    sec
    sbc #10
    sta eob
    lda ek_top          ; true top sits ek/8 rows above the snapped row:
    lsr                 ; round the texture anchor instead of flooring, or
    lsr                 ; adjacent columns jitter up to half a row
    clc                 ; (branchless: constant time, the M3 IRQ phase is
    adc eob             ; 1-cycle sensitive to composer timing variance)
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
    lda emit_lt
    sta exbyte          ; edge tiles read light/ramp from exbyte bits 6-7
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
    bmi @noupper
    beq @upsliver
    ldx #0
:   cmp #21
    bcc :+
    lsr
    inx
    jmp :-
:   stx vshift
    tax
    lda span_class,x
    jsr set_slice
    lda vtop
    sec
    sbc #10
    sta eob
    lda ek_top
    lsr
    lsr
    clc
    adc eob
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
    lda emit_lt         ; zero-row upper wall: top-edge fraction still shows
    sta exbyte
    lda #1
    sta ew_top
@noupper:
    ; lower wall [bb, b): span_l = vbot - vbbot (signed); off = y - (10+vbbot)
    lda vbot
    sec
    sbc vbbot
    bmi @nolower
    beq @losliver
    ldx #0
:   cmp #21
    bcc :+
    lsr
    inx
    jmp :-
:   stx vshift
    tax
    lda sl_tp_l         ; lower wall uses its own texture + ramp
    sta cur_tp
    lda sl_tp_l+1
    sta cur_tp+1
    lda sl_bp_l
    sta cur_bp
    lda sl_bp_l+1
    sta cur_bp+1
    lda span_class,x
    jsr set_slice
    lda vbbot
    clc
    adc #10
    eor #$FF
    clc
    adc #1
    sta eob
    lda bbot_acc        ; back-floor sub-row fraction: >= 4px means the
    and #$40            ; true top is over half a row below the snapped row
    lsr
    lsr
    lsr
    lsr
    lsr
    lsr
    sta mtmp
    lda eob
    sec
    sbc mtmp
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
    lda emit_lt         ; zero-row step: bottom-edge fraction still shows
    sta exbyte
    lda #1
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

set_slice:              ; A = class index -> tile_base, eclh, exbyte
    tax                 ; (reads through cur_tp/cur_bp = &tables[tex*101])
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
    lda exbyte
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
    lda exbyte
    and #$C0
    ora #EDGE_BANK
    sta (dst_ex),y
@neb:
.else
    lda ew_top
    beq @net
    lda ek_top
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
    sec
    sbc #1
    tay
    lda #EDGE_TOP_BASE
    clc
    adc ek_top
    sta (dst_nt),y
    lda exbyte
    and #$C0
    ora #FLAT_BANK
    sta (dst_ex),y
@net:
    lda ew_bot
    beq @neb
    lda ek_bot
    beq @neb
    lda vbot
    clc
    adc #10
    cmp b_row
    bne @neb
    lda b_row
    cmp floor0
    bcs @neb
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

emit_wall_run:          ; rows [ers, ere), NT = tile_base +
                        ; min((y+eob) >> vshift, eclh-1)
    ldy ers
@w:
    cpy ere
    bcs @done
    tya
    clc
    adc eob
    bpl :+
    lda #0              ; sub-row rounding can push the first row to -1
:   nop                 ; timing pad: without it the M3 IRQ-entry latency
    ldx vshift          ; phase-locks and ~16% of scanline reads land on 159
    beq :++
:   lsr
    dex
    bne :-
:   cmp eclh
    bcc :+
    lda eclh
    sbc #1              ; carry is set
:   clc
    adc tile_base
    sta (dst_nt),y
    lda exbyte
    sta (dst_ex),y
    iny
    bne @w
@done:
    rts

light_sh:
    .byte $00, $40, $80, $C0

; sector light -> first floor row at light-0 distance (z = 656/(row-10)
; through the 96/160/288 light bands; light-3 sectors are dark throughout)
fl_thr_tbl:
    .byte 13, 15, 17, 32

class_h_tbl:
    .byte 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20

; per-class phase extraction (texel width tw: phases = 64/tw,
; shift = log2(tw) - 2 + 3? no: phase = (uacc16 >> (8 + log2(tw))) via
; uacc+1 >> (log2(tw))... values below are lsr counts on uacc+1 hi byte)
class_pshift:           ; uacc+1 >> n (tw=4:2, 8:3, 16:4, 32:5, 64:5)
    .byte 5, 5, 5, 4, 4, 4, 4, 3, 3, 2, 2, 2, 2
class_pmask:            ; phases-1
    .byte 0, 1, 1, 3, 3, 3, 3, 7, 7, 15, 15, 15, 15
class_base_tbl:         ; cumulative phase counts per class
    .byte 0, 1, 3, 5, 9, 13, 17, 21, 29
    .byte 37, 53, 69, 85

span_class:             ; screen-row span -> smallest class >= span
    .byte 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 12, 12

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
