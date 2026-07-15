; BSP traversal v2: iterative front-to-back walk with an explicit stack.
;
; Node record (12B): px,py,pdx,pdy (s11.4), c0_idx, c0_isleaf, c1_idx,
; c1_isleaf. point_on_side: cross = (camx-px)*pdy - (camy-py)*pdx; side 0
; when >= 0 (identical to Doom's R_PointOnSide, so WAD child order is kept).
; Seg indices are 16-bit (E1M1-sized maps); node/subsector indices are bytes.
; find_sector locates the camera's subsector for eye-height computation.
.include "zeropage.inc"
.include "mmc5.inc"
.include "globals.inc"

.ifdef E1M1
.import draw_subsector_things
.endif

.import mul16s, do_seg, atan2_pg, angcol_tbl
.ifdef FULL_E1M1
.import map_segs0, map_segs1, map_nodes, SEG_BANK_SPLIT
.else
.import map_segs, map_nodes
.endif
.import ss_first_lo, ss_first_hi, ss_count, ss_sector
.import ss_bx1, ss_by1, ss_bx2, ss_by2
.import MAP_ROOT_NODE, REJECT_ROWB, reject_tbl
.export render_bsp, find_sector, find_subsector, load_seg, ceil_clip, floor_clip

.segment "BSS"
ceil_clip:  .res 32
floor_clip: .res 32
bsp_stack:  .res 64         ; 32 entries x (idx, isleaf)
.ifdef FULL_E1M1
wall_record: .res 12
.endif

.segment "CODE"

; ---------------------------------------------------------------------------
; bsp_node_ptr: tptr = &map_nodes[bsp_node]  (16-byte records)
; ---------------------------------------------------------------------------
bsp_node_ptr:
.ifdef FULL_E1M1
    lda #MAP_GEOM_BANK
    sta MMC5_PRG_A000
.endif
    lda bsp_node
    sta tptr
    lda #0
    sta tptr+1
    .repeat 4
    asl tptr
    rol tptr+1
    .endrepeat
    lda tptr
    clc
    adc #<map_nodes
    sta tptr
    lda tptr+1
    adc #>map_nodes
    sta tptr+1
    rts

; ---------------------------------------------------------------------------
; bbox_cull (Doom's R_CheckBBox): C set = cull the subtree — its two
; silhouette corners subtend an angle range that is either entirely outside
; the view frustum or covered by already-solid screen columns. Runs on
; page-byte bbox coords (bb_x1..bb_y2) via atan2_pg: two 8x8 hardware
; products total, no mul16s. Corners are expanded 1 page outward (bbox max
; edges are floor-truncated by the converter) so every error is outward.
; Keeps (C clear) when the camera is inside or within 4 pages of the box.
; ---------------------------------------------------------------------------
bbox_cull:
    ; camera region: cx/cy in 0..2 per axis -> region = cy*3 + cx
    ldx #0
    lda px+1
    cmp bb_x1
    bcc @gotx           ; west
    inx
    cmp bb_x2
    bcc @gotx           ; inside span
    beq @gotx
    inx                 ; east
@gotx:
    ldy #0
    lda py+1
    cmp bb_y1
    bcc @goty           ; south
    iny
    cmp bb_y2
    bcc @goty
    beq @goty
    iny                 ; north
@goty:
    tya
    asl
    sta rt_acc
    tya
    clc
    adc rt_acc
    sta rt_acc
    txa
    clc
    adc rt_acc
    cmp #4
    bne :+
    clc                 ; camera inside the box: never cull
    rts
:   tax                 ; X = region 0..8 (4 excluded)
    ; left silhouette corner -> angle
    lda bbc_xl,x
    jsr @pickx
    sec
    sbc px+1
    sta mtmp+2
    lda bbc_yl,x
    jsr @picky
    sec
    sbc py+1
    sta mtmp+3
    stx rt_acc          ; atan2_pg clobbers X
    jsr atan2_pg
    bcc :+
    jmp @keep           ; too close for page precision: keep
:   sta seg_a1
    ldx rt_acc
    ; right silhouette corner -> angle
    lda bbc_xr,x
    jsr @pickx
    sec
    sbc px+1
    sta mtmp+2
    lda bbc_yr,x
    jsr @picky
    sec
    sbc py+1
    sta mtmp+3
    jsr atan2_pg
    bcs @keep
    sta seg_a2
    ; same frustum-clip + occlusion scan shape as the do_seg angle gate
    lda seg_a1
    sec
    sbc seg_a2
    sta pf_span
    ; a box subtending ~180deg (camera hugging a long box) breaks the clip
    ; arithmetic below (page-corner error inflates span past 128) -> keep
    cmp #124
    bcc :+
    jmp @keep
:   lda seg_a1
    sec
    sbc pang+1
    clc
    adc #PF_CLIP
    cmp #2*PF_CLIP+1
    bcc @b1ok
    sec
    sbc #2*PF_CLIP
    sec
    sbc #4
    bcc @b1cl
    cmp pf_span
    bcc @b1cl
    sec                 ; entirely off the left / behind
    rts
@b1cl:
    lda #2*PF_CLIP
@b1ok:
    sta pf_c
    lda seg_a2
    sec
    sbc pang+1
    clc
    adc #PF_CLIP
    cmp #2*PF_CLIP+1
    bcc @b2ok
    eor #$FF
    sec
    sbc #3              ; (256 - idx2) - 4
    bcc @b2cl
    cmp pf_span
    bcc @b2cl
    sec                 ; entirely off the right
    rts
@b2cl:
    lda #0
@b2ok:
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
@occ:
    lda ceil_clip,y
    cmp floor_clip,y
    bcc @keep           ; open column inside the box's range
    cpy pf_r
    iny
    bcc @occ
    sec                 ; box fully behind solid columns
    rts
@keep:
    clc
    rts
@pickx:                 ; A = selector: 0 -> x1-1, 1 -> x2+1 (expand outward)
    bne :+
    lda bb_x1
    sec
    sbc #1
    rts
:   lda bb_x2
    clc
    adc #1
    rts
@picky:
    bne :+
    lda bb_y1
    sec
    sbc #1
    rts
:   lda bb_y2
    clc
    adc #1
    rts

; silhouette corner selectors per camera region (region 4 = inside, unused)
bbc_xl: .byte 0, 0, 0, 0, 0, 1, 1, 1, 1
bbc_yl: .byte 1, 0, 0, 1, 0, 0, 1, 1, 0
bbc_xr: .byte 1, 1, 1, 0, 0, 1, 0, 0, 0
bbc_yr: .byte 0, 0, 1, 0, 0, 1, 0, 1, 1

; ---------------------------------------------------------------------------
; node_side: computes the camera's side of node at tptr.
; Returns Y = 8 (side 0) or 10 (side 1) = offset of the NEAR child pair.
; ---------------------------------------------------------------------------
node_side:
    inc nodes_visited
    ; dx = camera - partition origin
    ldy #0
    lda px
    sec
    sbc (tptr),y
    sta rt_dx
    iny
    lda px+1
    sbc (tptr),y
    sta rt_dx+1
    iny
    lda py
    sec
    sbc (tptr),y
    sta rt_dy
    iny
    lda py+1
    sbc (tptr),y
    sta rt_dy+1
    ; Most Doom BSP partitions are axis-aligned.  Their cross-product sign
    ; needs no multiplication: cross = dx*pdy for vertical partitions and
    ; cross = -(dy*pdx) for horizontal partitions.  Explicit zero tests keep
    ; the existing cross==0 -> side 0 rule.
    ldy #4
    lda (tptr),y
    iny
    ora (tptr),y
    beq @vertical
    ldy #6
    lda (tptr),y
    iny
    ora (tptr),y
    beq @horizontal
    ; dx * pdy
    ldy #6
    lda (tptr),y
    sta mul_b
    iny
    lda (tptr),y
    sta mul_b+1
    lda rt_dx
    sta mul_a
    lda rt_dx+1
    sta mul_a+1
    jsr mul16s
    lda mul_r
    sta rt_acc
    lda mul_r+1
    sta rt_acc+1
    lda mul_r+2
    pha
    lda mul_r+3
    pha
    ; dy * pdx
    ldy #4
    lda (tptr),y
    sta mul_b
    iny
    lda (tptr),y
    sta mul_b+1
    lda rt_dy
    sta mul_a
    lda rt_dy+1
    sta mul_a+1
    jsr mul16s
    ; sign of cross = P1 - P2 (P1 lo16 in rt_acc; bytes 2,3 pushed, 2 first;
    ; PLA preserves carry)
    lda rt_acc
    sec
    sbc mul_r
    lda rt_acc+1
    sbc mul_r+1
    pla                 ; P1 byte 3
    tax
    pla                 ; P1 byte 2
    sbc mul_r+2
    txa
    sbc mul_r+3
    bpl @side0
@side1:
    ldy #10
    rts
@vertical:
    ldy #6              ; malformed zero-length partition still has cross=0
    lda (tptr),y
    iny
    ora (tptr),y
    beq @side0
    lda rt_dx
    ora rt_dx+1
    beq @side0
    ldy #7
    lda rt_dx+1
    eor (tptr),y
    bmi @side1
    bpl @side0
@horizontal:
    lda rt_dy
    ora rt_dy+1
    beq @side0
    ldy #5
    lda rt_dy+1
    eor (tptr),y
    bmi @side0           ; negative product -> positive negated cross
    bpl @side1
@side0:
    ldy #8
    rts

; ---------------------------------------------------------------------------
render_bsp:
    ldy #31
    lda #0
@ic:
    sta ceil_clip,y
    dey
    bpl @ic
    ldy #31
    lda #VIEW_ROWS
@if:
    sta floor_clip,y
    dey
    bpl @if
    lda #0
    sta solid_cnt
    sta bsp_sp
    sta bsp_leaf
    lda #<MAP_ROOT_NODE
    sta bsp_node
@walk:
    lda bsp_leaf
    beq @node
    jmp @leaf
@node:
    jsr bsp_node_ptr
    ldy #12             ; subtree bbox -> zp for the shared cull
    lda (tptr),y
    sta bb_x1
    iny
    lda (tptr),y
    sta bb_y1
    iny
    lda (tptr),y
    sta bb_x2
    iny
    lda (tptr),y
    sta bb_y2
    jsr bbox_cull
    bcc :+
    jmp @pop            ; whole subtree outside the view
:   jsr node_side
    ; push far child (the pair at Y^2), descend into near
    lda (tptr),y
    pha                 ; near idx
    iny
    lda (tptr),y
    pha                 ; near isleaf
    tya
    eor #%00000010      ; 9^2=11, 11^2=9 -> other pair's isleaf slot
    tay
    ldx bsp_sp
    lda (tptr),y
    sta bsp_stack+1,x   ; far isleaf
    dey
    lda (tptr),y
    sta bsp_stack,x     ; far idx
    inx
    inx
    stx bsp_sp
    pla
    sta bsp_leaf
    pla
    sta bsp_node
    jmp @walk
@leaf:
    ldx bsp_node
    jsr draw_subsector
    lda solid_cnt
    cmp #VIEW_COLS
    bcs @done
@pop:
    lda bsp_sp
    beq @done
    sec
    sbc #2
    sta bsp_sp
    tax
    lda bsp_stack,x
    sta bsp_node
    lda bsp_stack+1,x
    sta bsp_leaf
    jmp @walk
@done:
    rts

; ---------------------------------------------------------------------------
draw_subsector:         ; X = subsector index
.ifdef FULL_E1M1
    lda #MAP_COMMON_BANK
    sta MMC5_PRG_A000
.endif
    ; WAD REJECT: skip the whole subsector if its sector is precomputed as
    ; invisible from the camera's sector (rj_ptr set in render_frame)
    lda ss_sector,x
    pha
    lsr
    lsr
    lsr
    tay
    lda (rj_ptr),y
    sta rt_acc
    pla
    and #7
    tay
    lda bit_tbl,y
    and rt_acc
    beq :+
    rts
:   ; leaf-level bbox cull (much tighter than the node unions)
    lda ss_bx1,x
    sta bb_x1
    lda ss_by1,x
    sta bb_y1
    lda ss_bx2,x
    sta bb_x2
    lda ss_by2,x
    sta bb_y2
    txa
    pha
    jsr bbox_cull
    pla
    tax
    bcc :+
    rts
:
.ifdef E1M1
    txa
    pha
    jsr draw_subsector_things
    pla
    tax
.endif
    lda ss_first_lo,x
    sta ss_idx
    lda ss_first_hi,x
    sta ss_idx_hi
    lda ss_count,x
    sta ss_n
@sl:
    jsr load_seg
    jsr do_seg
    inc ss_idx
    bne :+
    inc ss_idx_hi
:   dec ss_n
    bne @sl
    rts

load_seg:
.ifdef FULL_E1M1
; Copy one 12-byte seg record from its ROM bank so do_seg can freely switch
; the $A000 window while fetching 16-bit vertices and common map metadata.
    lda ss_idx
    sta wall_ptr
    lda ss_idx_hi
    sta wall_ptr+1
    cmp #>SEG_BANK_SPLIT
    bcc @bank0
    bne @bank1
    lda ss_idx
    cmp #<SEG_BANK_SPLIT
    bcc @bank0
@bank1:
    lda #1
    sta FULL_SEG1_SEEN
    lda wall_ptr
    sec
    sbc #<SEG_BANK_SPLIT
    sta wall_ptr
    lda wall_ptr+1
    sbc #>SEG_BANK_SPLIT
    sta wall_ptr+1
    lda #MAP_SEG1_BANK
    bne @bank_ready
@bank0:
    lda #MAP_SEG0_BANK
@bank_ready:
    sta MMC5_PRG_A000
    ; record offset = local index * 12 = index * 4 + index * 8
    asl wall_ptr
    rol wall_ptr+1
    asl wall_ptr
    rol wall_ptr+1
    lda wall_ptr
    sta rt_acc
    lda wall_ptr+1
    sta rt_acc+1
    asl wall_ptr
    rol wall_ptr+1
    lda wall_ptr
    clc
    adc rt_acc
    sta wall_ptr
    lda wall_ptr+1
    adc rt_acc+1
    clc
    adc #$A0
    sta wall_ptr+1
    ldy #11
@copy:
    lda (wall_ptr),y
    sta wall_record,y
    dey
    bpl @copy
    lda #MAP_COMMON_BANK
    sta MMC5_PRG_A000
    lda #<wall_record
    sta wall_ptr
    lda #>wall_record
    sta wall_ptr+1
    rts
.else
    ; wall_ptr = map_segs + seg_idx*10  (idx*2 + idx*8)
    lda ss_idx
    sta wall_ptr
    lda ss_idx_hi
    sta wall_ptr+1
    asl wall_ptr
    rol wall_ptr+1      ; *2
    lda wall_ptr
    sta rt_acc
    lda wall_ptr+1
    sta rt_acc+1
    asl wall_ptr
    rol wall_ptr+1
    asl wall_ptr
    rol wall_ptr+1      ; *8
    lda wall_ptr
    clc
    adc rt_acc
    sta wall_ptr
    lda wall_ptr+1
    adc rt_acc+1
    sta wall_ptr+1
    lda wall_ptr
    clc
    adc #<map_segs
    sta wall_ptr
    lda wall_ptr+1
    adc #>map_segs
    sta wall_ptr+1
    rts
.endif

bit_tbl:
    .byte $01, $02, $04, $08, $10, $20, $40, $80

; ---------------------------------------------------------------------------
; find_subsector: point-locate px/py -> X (subsector index)
; ---------------------------------------------------------------------------
find_subsector:
    lda #0
    sta bsp_leaf
    lda #<MAP_ROOT_NODE
    sta bsp_node
@walk:
    lda bsp_leaf
    bne @leaf
    jsr bsp_node_ptr        ; no bbox cull: must find the true containing leaf
    jsr node_side
    lda (tptr),y        ; near child = the one containing the camera
    pha
    iny
    lda (tptr),y
    sta bsp_leaf
    pla
    sta bsp_node
    jmp @walk
@leaf:
    ldx bsp_node
    rts

; Point-locate the camera and load its sector.
find_sector:
    jsr find_subsector
.ifdef FULL_E1M1
    lda #MAP_COMMON_BANK
    sta MMC5_PRG_A000
.endif
    lda ss_sector,x
    sta cam_sec
    rts
