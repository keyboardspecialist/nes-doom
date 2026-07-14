; Zero-page map — single source of truth. Fixed addresses so the Mesen lua
; test harness can read them without symbol lookup.
;
;   $00-$0F system    $10-$1F pusher     $20-$2F math (never touched by NMI/IRQ)
;   $30-$3F camera    $40-$5F bsp/render $60-$7F emit
;   $80-$8F profiling (read by lua)      $90-$CF scratch   $D0-$FF reserved
.ifndef ZEROPAGE_INC
ZEROPAGE_INC = 1

; --- system $00-$0F ---
frame_cnt   = $00
nmi_flags   = $01
ppu2000_sh  = $02
ppu2001_sh  = $03
irq_phase   = $04
joy1        = $05
joy1_prev   = $06
rng         = $07
heartbeat   = $08
irq_cnt     = $09
exram_ok    = $0A   ; $A5 = ExRAM mode-%10 round trip passed
sleeping    = $0B

; --- pusher $10-$1F ---
push_buf    = $10
push_col    = $11
push_quota  = $12
front_buf   = $13
flip_cnt    = $14   ; 16-bit
flip_cnt_hi = $15
prg8000_sh  = $16   ; main-thread shadow of $5114 (write-only register)
back_ready  = $17   ; composer -> pusher: back buffer holds a finished frame
push_active = $18   ; a push_run is in flight (NMI must not start another)
push_vec    = $1A   ; 16-bit dispatch vector
uoz_step    = $1C   ; 16-bit, signed: per-column step of uoz (main thread;
                    ; $1C-$1F are unused by the NMI/IRQ pusher code)

; --- math $20-$2F ---
mul_a       = $20   ; 16-bit
mul_b       = $22   ; 16-bit
mul_r       = $24   ; 32-bit
mtmp        = $28   ; 4 bytes
msign       = $2C
vtmp        = $2D   ; vert_angle: vertex index / cache scratch
vmask       = $2E

; --- camera $30-$3F ---
px          = $30   ; s11.4
py          = $32
pang        = $34   ; 16-bit BAM
vsin        = $36   ; s0.8.8
vcos        = $38

; --- bsp/render $40-$5F ---
node_ptr    = $40
seg_ptr     = $42
tx1         = $44   ; s7.8 camera-space
tz1         = $46
tx2         = $48
tz2         = $4A
col_l       = $4C
col_r       = $4D
bsp_sp      = $4E

; --- emit $60-$7F ---
cur_col     = $60
wtop        = $61
wbot        = $62
hclass      = $63
uphase      = $64
light       = $65
lut_ptr     = $66   ; 16-bit
dst_nt      = $68   ; 16-bit
dst_ex      = $6A   ; 16-bit
tile_base   = $6C
exbyte      = $6D

; --- render frame state $50-$5F ---
rf_t0       = $50
wall_ptr    = $52   ; 16-bit
rzh1        = $54   ; 16-bit, 524288/z at left column (interpolated)
rzh2        = $56
rzstep      = $58
ustep       = $5A   ; texture u step, 8.8
uacc        = $5C   ; texture u accumulator, 8.8 (wraps mod 256 texels)
rf_back     = $5E   ; back buffer index (front_buf ^ 1)
rf_backoff  = $5F   ; rf_back << 5 for colbase table indexing

; --- milestone scratch $90-$9F (M2DEMO build only; game build reuses) ---
m2_row      = $90
m2_end      = $91
m2_ptr      = $92   ; 16-bit
m2_fill_req = $94   ; IRQ one-shot: fill ExRAM rows 10-19 during rendering
m2_5130_done = $95
m2_palbits  = $96

; --- wall workspace $90-$AF (game build) ---
wx          = $90   ; 16-bit world point in
wy          = $92
cx1         = $94   ; 16-bit signed projected columns
cx2         = $96
ulen        = $98   ; wall length in texels (<= 255)
tclip       = $9A   ; near-clip fraction; reused at emit time as ew_top
wall_cnt    = $9B   ; (M4-era) reused at emit time as ew_bot
ew_top      = $9A   ; "a wall run was drawn at the t boundary" -> edge tile ok
ew_bot      = $9B
ttx         = $9C   ; transform output, s11.4 camera space
ttz         = $9E
rt_dx       = $A0
rt_dy       = $A2
rt_acc      = $A4
uend        = $A6   ; texture u at right end, 8.8
tptr        = $A8   ; table pointer (recipf is 1KB, spans pages)
du88        = $AA
n0c         = $AC   ; clamped column span
at_sx       = $AD   ; atan2_hi octant flags: dx sign, dy sign, |dy|>|dx|
at_sy       = $AE
at_sw       = $AF

; --- profiling $80-$8F (lua-visible) ---
pass_frames = $80
cols_drawn  = $81
segs_drawn  = $82
nodes_visited = $83
rj_ptr      = $84   ; 16-bit: &reject_tbl[cam_sec * REJECT_ROWB]
bb_x1       = $86   ; bbox under test (page bytes) for bbox_cull
bb_y1       = $87
bb_x2       = $88
bb_y2       = $89
uoz_acc     = $8A   ; 16-bit: u * rzh / 256 — linear in screen x, so exact
                    ; u = (uoz << 16) / rzh at any column (perspective u)
ek_top      = $8C   ; sub-tile pixel remainders of the wall boundaries
ek_bot      = $8D
persp_cnt   = $8E   ; perspective-u resync countdown; 0 = affine-only seg
zp_canary   = $8F   ; must stay $C5

; --- seg height interpolators $B0-$BF (h * rzh >> 8, linear in screen x) ---
ytop_acc    = $B0   ; front ceiling
ytop_step   = $B2
ybot_acc    = $B4   ; front floor
ybot_step   = $B6
btop_acc    = $B8   ; back ceiling (two-sided)
btop_step   = $BA
bbot_acc    = $BC   ; back floor
bbot_step   = $BE

; --- seg/emit state $C0-$DF ---
seg_texoff  = $C0   ; scratch: texture slot byte during do_seg fetch
seg_light   = $C1
seg_back    = $C2
two_sided   = $C3
solid_cnt   = $C4
ss_idx      = $C5
ss_n        = $C6
bsp_node    = $C7
vtop        = $C8   ; per-column height offsets (rows above/below horizon)
vbot        = $C9
vbtop       = $CA
vbbot       = $CB
ceil0       = $CC   ; column clip window [ceil0, floor0)
floor0      = $CD
ers         = $CE   ; emit run start/end
ere         = $CF
eob         = $D0   ; texture row offset bias (off = y + eob)
eclh        = $D1   ; class height for offset clamp
emit_lt     = $D2   ; light<<6 for this column
t_row       = $D3
b_row       = $D4
bt_row      = $D5
bb_row      = $D6
seg_hc      = $D7   ; sector heights relative to the eye (SIGNED bytes)
seg_hf      = $D8
seg_bhc     = $D9
seg_bhf     = $DA
pf_r        = $DB   ; angle-prefilter occlusion scan end column (inclusive)
eye_h       = $DC   ; sec_floor[cam_sec] + EYE_REL, signed
cam_sec     = $DD
ss_idx_hi   = $DE   ; 16-bit seg index high byte (ss_idx = $C5 is the low)
bsp_leaf    = $DF   ; current BSP ref is a subsector

; --- slice LUT pointers $E0-$EB (per-seg; cur pair selected per wall part) ---
sl_tp       = $E0   ; mid/upper: &slice_tile[tex*104]
sl_bp       = $E2
sl_tp_l     = $E4   ; lower wall texture
sl_bp_l     = $E6
cur_tp      = $E8
cur_bp      = $EA
seg_a1      = $EC   ; angle prefilter: endpoint angles (BAM hi-byte)
seg_a2      = $ED
pf_span     = $EE   ; a1 - a2 (mod 256)
pf_c        = $EF   ; clamped left-endpoint angle index (a1_rel + PF_CLIP)
dx1         = $F0   ; saved v1 camera-relative deltas (z-first transform)
dy1         = $F2
dx2         = $FC   ; saved v2 camera-relative deltas
dy2         = $FE

.endif
