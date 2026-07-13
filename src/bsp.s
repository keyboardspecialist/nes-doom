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

.import mul16s, do_seg
.import map_segs, map_nodes
.import ss_first_lo, ss_first_hi, ss_count, ss_sector
.import MAP_ROOT_NODE, REJECT_ROWB, reject_tbl
.export render_bsp, find_sector, ceil_clip, floor_clip

.segment "BSS"
ceil_clip:  .res 32
floor_clip: .res 32
bsp_stack:  .res 64         ; 32 entries x (idx, isleaf)

.segment "CODE"

; ---------------------------------------------------------------------------
; bsp_node_ptr: tptr = &map_nodes[bsp_node]  (16-byte records)
; ---------------------------------------------------------------------------
bsp_node_ptr:
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
; node_behind: C set if the node's subtree bbox lies entirely behind the
; camera plane. Picks the bbox corner farthest along the view direction
; (record offsets 12-15 = x1,y1,x2,y2 page bytes) and dots it with the view
; vector in page units; 3 pages of slack cover the byte granularity.
; ---------------------------------------------------------------------------
node_behind:
    ldy #14             ; bx2
    lda vcos+1
    bpl :+
    ldy #12             ; bx1
:   ldx #0
    lda (tptr),y
    sec
    sbc px+1
    sta mul_a
    bpl :+
    dex
:   stx mul_a+1
    lda vcos
    sta mul_b
    lda vcos+1
    sta mul_b+1
    jsr mul16s
    lda mul_r+1
    sta rt_acc
    lda mul_r+2
    sta rt_acc+1
    ldy #15             ; by2
    lda vsin+1
    bpl :+
    ldy #13
:   ldx #0
    lda (tptr),y
    sec
    sbc py+1
    sta mul_a
    bpl :+
    dex
:   stx mul_a+1
    lda vsin
    sta mul_b
    lda vsin+1
    sta mul_b+1
    jsr mul16s
    lda rt_acc
    clc
    adc mul_r+1
    sta rt_acc
    lda rt_acc+1
    adc mul_r+2
    ; behind if z_pages + 3 < 0
    tax
    lda rt_acc
    clc
    adc #3
    txa
    adc #0
    bpl :+
    jmp @cull
:

    ; --- left frustum edge (pang+45): cull if the box is entirely left.
    ; cross(dL,B) = dLx*By - dLy*Bx, minimized over corners; cull if > slack.
    ldy #13             ; y1 when dLx >= 0
    lda vcos_l+1
    bpl :+
    ldy #15
:   ldx #0
    lda (tptr),y
    sec
    sbc py+1
    sta mul_a
    bpl :+
    dex
:   stx mul_a+1
    lda vcos_l
    sta mul_b
    lda vcos_l+1
    sta mul_b+1
    jsr mul16s
    lda mul_r+1
    sta rt_acc
    lda mul_r+2
    sta rt_acc+1
    ldy #14             ; x2 when dLy >= 0
    lda vsin_l+1
    bpl :+
    ldy #12
:   ldx #0
    lda (tptr),y
    sec
    sbc px+1
    sta mul_a
    bpl :+
    dex
:   stx mul_a+1
    lda vsin_l
    sta mul_b
    lda vsin_l+1
    sta mul_b+1
    jsr mul16s
    lda rt_acc
    sec
    sbc mul_r+1
    sta rt_acc
    lda rt_acc+1
    sbc mul_r+2
    tax
    lda rt_acc
    sec
    sbc #5              ; cull if min_cross > 4 pages
    txa
    sbc #0
    bmi :+
    jmp @cull
:

    ; --- right frustum edge (pang-45): cull if entirely right.
    ; cross maximized over corners; cull if < -slack.
    ldy #15             ; y2 when dRx >= 0
    lda vcos_r+1
    bpl :+
    ldy #13
:   ldx #0
    lda (tptr),y
    sec
    sbc py+1
    sta mul_a
    bpl :+
    dex
:   stx mul_a+1
    lda vcos_r
    sta mul_b
    lda vcos_r+1
    sta mul_b+1
    jsr mul16s
    lda mul_r+1
    sta rt_acc
    lda mul_r+2
    sta rt_acc+1
    ldy #12             ; x1 when dRy >= 0
    lda vsin_r+1
    bpl :+
    ldy #14
:   ldx #0
    lda (tptr),y
    sec
    sbc px+1
    sta mul_a
    bpl :+
    dex
:   stx mul_a+1
    lda vsin_r
    sta mul_b
    lda vsin_r+1
    sta mul_b+1
    jsr mul16s
    lda rt_acc
    sec
    sbc mul_r+1
    sta rt_acc
    lda rt_acc+1
    sbc mul_r+2
    tax
    lda rt_acc
    clc
    adc #5              ; cull if max_cross < -4 pages
    txa
    adc #0
    bmi @cull
    clc
    rts
@cull:
    sec
    rts

; ---------------------------------------------------------------------------
; node_side: computes the camera's side of node at tptr.
; Returns Y = 8 (side 0) or 10 (side 1) = offset of the NEAR child pair.
; ---------------------------------------------------------------------------
node_side:
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
    ldy #10
    rts
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
    jsr node_behind
    bcc :+
    jmp @pop            ; whole subtree behind the camera
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
:   lda ss_first_lo,x
    sta ss_idx
    lda ss_first_hi,x
    sta ss_idx_hi
    lda ss_count,x
    sta ss_n
@sl:
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
    jsr do_seg
    inc ss_idx
    bne :+
    inc ss_idx_hi
:   dec ss_n
    bne @sl
    rts

bit_tbl:
    .byte $01, $02, $04, $08, $10, $20, $40, $80

; ---------------------------------------------------------------------------
; find_sector: point-locate the camera -> cam_sec (sector index)
; ---------------------------------------------------------------------------
find_sector:
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
    lda ss_sector,x
    sta cam_sec
    rts
