; Reset, MMC5 init, ExRAM self-test, main loop.
; Everything on the reset path lives in FIXED ($E000) because only $5117 is
; guaranteed (last bank) at power-on.
;
; M2DEMO build: static ExAttr diagnostic pattern + $5130 flip at frame 120.
; M3+ build: composer loop — procedurally fills the back compose buffer and
; hands it to the IRQ/NMI band pusher (see vram_push.s) via back_ready.
.include "zeropage.inc"
.include "mmc5.inc"
.include "globals.inc"

.import nmi_handler, irq_handler, bg_palettes
.ifdef E1M1
    .import hud_nt, hud_ex, sec_pal, sprite_palettes
    .import init_oam_set
    .import show_title
    .import audio_init
    .import thing_x_lo, thing_x_hi, thing_y_lo, thing_y_hi, thing_kind
    .import monster_thing_idx, monster_spawn_ss
    .import MAP_THING_COUNT, MONSTER_COUNT
.endif
.ifndef M2DEMO
.import render_frame, init_camera
.endif
.export reset, fill_exram_rows

.segment "FIXED"

reset:
    sei
    cld
    ldx #$40
    stx $4017           ; APU frame IRQ off
    ldx #$FF
    txs
    inx                 ; X = 0
    stx $2000           ; NMI off
    stx $2001           ; rendering off
    stx $4010           ; DMC IRQ off
    stx $4015           ; all APU channels off while they are configured

    bit $2002
@vwait1:
    bit $2002
    bpl @vwait1

    ; clear RAM (skip $0200 OAM page, set separately)
    lda #0
    tax
@clrram:
    sta $0000,x
    sta $0100,x
    sta $0300,x
    sta $0400,x
    sta $0500,x
    sta $0600,x
    sta $0700,x
    inx
    bne @clrram
    lda #$FF            ; OAM shadow: all sprites offscreen
@clroam:
    sta $0200,x
    inx
    bne @clroam

    lda #$C5
    sta zp_canary
    lda #$A5            ; deterministic nonzero combat RNG seed
    sta rng

@vwait2:
    bit $2002
    bpl @vwait2

    jsr mmc5_init
    jsr exram_selftest  ; leaves ExRAM zeroed, mode %10
.ifdef E1M1
    jsr show_title
.endif

.ifdef M2DEMO
    ; rows 0-9 written here in mode %10 during forced blank; the line-160 IRQ
    ; writes rows 10-19 in mode %01 during rendering — both paths must display
    lda #0
    sta m2_row
    lda #10
    sta m2_end
    jsr fill_exram_rows
.else
    ; status bar cells (rows 20-24, lines 160-199)
.ifdef E1M1
    ; Both buffers and the initial display use sector 0.  Later render passes
    ; attach their sector to the back buffer without touching pal_sec.
    lda #<sec_pal
    sta pal_ptr
    lda #>sec_pal
    sta pal_ptr+1
    lda #0
    sta BUFA_PAL_SEC
    sta BUFA_PAL_SEC+1
.endif
    ldx #0
.ifdef E1M1
@stbar:
    lda hud_ex,x        ; HUD bank + per-tile palette from tilegen
    sta EXRAM + 20*32,x
    inx
    cpx #160
    bne @stbar
.else
    lda #$40 | FLAT_BANK
@stbar:
    sta EXRAM + 20*32,x
    inx
    cpx #160
    bne @stbar
.endif
    ; zero both compose buffers ($6000-$69FF) so the first pushes are defined
    lda #0
    sta m2_ptr
    lda #$60
    sta m2_ptr+1
    ldy #0
    tya
@clrbuf:
    sta (m2_ptr),y
    iny
    bne @clrbuf
    inc m2_ptr+1
    ldx m2_ptr+1
    cpx #$6A
    bne @clrbuf
.ifdef E1M1
    ; Persistent gameplay state occupies the otherwise unused $6A page.
    ldx #<(MAX_THINGS / 8 - 1)
    lda #$FF
@activate_things:
    sta THING_ACTIVE,x
    dex
    bpl @activate_things ; unused tail bits are harmless
    lda #50
    sta PL_AMMO
    lda #100
    sta PL_HEALTH
    lda #0
    sta PL_ARMOR
    sta PL_ARMOR_TYPE
    sta HUD_DIRTY       ; generated HUD already shows 50 / 100% / 0%
    sta FACE_WANT       ; frame 0 = healthy STFST01
    sta FACE_SHOWN
    sta FACE_TIMER
    sta FACE_HIT_SEEN
    sta FACE_IDLE_TIMER
    sta FACE_IDLE_PHASE
    sta WEAPON_FRAME
    sta WEAPON_TIMER
    sta SHOT_COUNT
    sta PICKUP_COUNT
    sta SHOT_SEEN
    sta SHOT_PENDING
    sta SHOT_TARGET
    sta SHOT_BEST_LO
    sta SHOT_BEST_HI
    sta HIT_COUNT
    sta BARREL_KILLS
    sta EXPLOSION_SOUND_PENDING
    sta BUFA_EXPLOSION_SOUND
    sta BUFA_EXPLOSION_SOUND+1
    sta EXPLOSION_RENDER_COUNT
    sta ENEMY_SOUND_PENDING
    sta ZOMBIE_KILLS
    sta ENEMY_ATTACKS
    sta ENEMY_HITS
    sta EXPLOSION_OAM_COUNT
    sta LEVEL_COMPLETE
    sta PICKUP_SOUND_PENDING
    sta PLAYER_PAIN_SOUND_PENDING
    sta DOOR_SOUND_PENDING
    sta EXIT_SOUND_PENDING
.ifdef FULL_E1M1
    sta FULL_SEG1_SEEN
    sta FULL_HIGH_VERTEX_SEEN
.endif
    ldx #7
@clear_exp_sound_bits:
    sta THING_EXP_SOUND_SENT,x
    dex
    bpl @clear_exp_sound_bits
    ldx #<(MAX_THINGS - 1)
    lda #0
@clear_thing_combat:
    sta THING_HEALTH,x
    sta THING_DEATH_AT,x
    dex
    bpl @clear_thing_combat
    ldx #0
@init_thing_health:
    cpx #<MAP_THING_COUNT
    bcs @thing_health_done
    lda thing_kind,x
    cmp #3
    beq @thing_has_health
    cmp #4
    beq @thing_has_health
    cmp #13
    bne :+
@thing_has_health:
    lda #20
    sta THING_HEALTH,x
:   inx
    bne @init_thing_health
@thing_health_done:
    ldx #0
@init_monsters:
    cpx #<MONSTER_COUNT
    bcs @monsters_done
    ldy monster_thing_idx,x
    lda thing_x_lo,y
    sta MONSTER_X_LO,x
    lda thing_x_hi,y
    sta MONSTER_X_HI,x
    lda thing_y_lo,y
    sta MONSTER_Y_LO,x
    lda thing_y_hi,y
    sta MONSTER_Y_HI,x
    lda monster_spawn_ss,x
    sta MONSTER_SS,x
    lda #0
    sta MONSTER_LAST_MOVE,x
    sta MONSTER_LAST_ATTACK,x
    inx
    bne @init_monsters
@monsters_done:
.endif
.endif
    mmc5_exram_attr_mode

    jsr ppu_init

.ifdef E1M1
    jsr audio_init
    ; Seed every weapon-frame page in the two compose-owned sets and the
    ; initial stable display set.
    lda #>OAMA
    jsr init_oam_set
    lda #>OAMB
    jsr init_oam_set
    lda #>OAMC
    jsr init_oam_set
    lda #>OAMA
    sta BUFA_OAM_SET
    lda #>OAMB
    sta BUFA_OAM_SET+1
    lda #>OAMC
    sta oam_dma_set
    lda #0
    sta $2003
    lda oam_dma_set
    clc
    adc WEAPON_FRAME
    sta $4014           ; prime the first frame; NMI refreshes OAM thereafter

.endif

    ; rendering on
.ifdef E1M1
    lda #VIEW_MASK
.else
    lda #STATUS_MASK
.endif
    sta ppu2001_sh
    sta $2001
.ifdef E1M1
    lda #%10101000      ; NMI on, MMC5-independent 8x16 sprites, VRAM inc +1
.else
    lda #%10001000      ; NMI on, BG $0000, VRAM inc +1
.endif
    sta ppu2000_sh
    sta $2000

.ifdef M2DEMO
    lda #1
    sta m2_fill_req
.else
    jsr init_camera
.endif

    ; arm scanline IRQ at the status-bar split line
    lda #160
    sta MMC5_IRQ_CMP
    lda #$80
    sta MMC5_IRQ_EN
    cli

.ifdef M2DEMO
main_loop:
    inc heartbeat
    ; M2 phase B: after 120 frames, page CHR to the second 256KB window
    lda m2_5130_done
    bne @no5130
    lda frame_cnt
    cmp #120
    bcc @no5130
    lda #1
    sta MMC5_CHR_HI
    sta m2_5130_done
@no5130:
    jmp main_loop
.else
; Renderer loop: render the scene into the back compose buffer, flag it
; ready, wait for the pusher to swap it in, repeat. The pusher owns
; front_buf/push_col; we own the back buffer.
main_loop:
    inc heartbeat
    jsr render_frame
.ifdef E1M1
    lda LEVEL_COMPLETE
    beq :+
@wait_exit_sound:
    lda EXIT_SOUND_PENDING
    bne @wait_exit_sound
    lda NOISE_HOLD
    bne @wait_exit_sound
    jmp reset
:
.endif
    lda #1
    sta back_ready
@wait:
    lda back_ready
    bne @wait
    jmp main_loop
.endif

mmc5_init:
    lda #3
    sta MMC5_PRG_MODE   ; four 8KB banks
    sta MMC5_CHR_MODE   ; 1KB sprite banks (BG banking comes from ExAttr)
    lda #2
    sta MMC5_RAM_PROT1
    lda #1
    sta MMC5_RAM_PROT2
    lda #0
    sta MMC5_NT_MAP     ; all logical nametables -> CIRAM0 (single screen)
    sta MMC5_FILL_TILE
    sta MMC5_FILL_ATTR
    sta MMC5_RAM_BANK
    sta MMC5_SPLIT_CTRL
    ; PRG windows: bit7 = ROM
    lda #$80
    sta MMC5_PRG_8000   ; bank 0 (LUTs)
    sta prg8000_sh
    lda #$81
    sta MMC5_PRG_A000   ; bank 1
    lda #$8E
    sta MMC5_PRG_C000   ; CODE
    lda #$0F
    sta MMC5_PRG_E000   ; FIXED (already there at power-on; be explicit)
.ifdef E1M1
    ; Pages 256-261 hold the static world atlas; 262-263 are weapon frame 0.
    ; NMI changes only the final pair as the weapon animates.
    lda #>SPRITE_CHR_PAGE
    sta MMC5_CHR_HI
    ldx #7
@sprbanks:
    txa
    sta MMC5_CHR_SPR0,x
    dex
    bpl @sprbanks
    lda #0
    sta MMC5_CHR_HI
.else
    lda #0
    sta MMC5_CHR_HI
    ldx #7
@sprbanks:
    txa
    sta MMC5_CHR_SPR0,x
    dex
    bpl @sprbanks
.endif
    rts

; Round-trip all 1KB of ExRAM in mode %10. Result in exram_ok: $A5 = pass.
; Leaves ExRAM zeroed and the mode at %10 (caller switches to ExAttr).
exram_selftest:
    mmc5_exram_cpu_mode
    ldx #0
@fill:
    txa
    eor #$A5
    sta EXRAM,x
    sta EXRAM+$100,x
    sta EXRAM+$200,x
    sta EXRAM+$300,x
    inx
    bne @fill
    ldx #0
@check:
    txa
    eor #$A5
    cmp EXRAM,x
    bne @fail
    cmp EXRAM+$100,x
    bne @fail
    cmp EXRAM+$200,x
    bne @fail
    cmp EXRAM+$300,x
    bne @fail
    inx
    bne @check
    lda #$A5
    bne @done
@fail:
    lda #$FF
@done:
    sta exram_ok
    lda #0
    tax
@wipe:
    sta EXRAM,x
    sta EXRAM+$100,x
    sta EXRAM+$200,x
    sta EXRAM+$300,x
    inx
    bne @wipe
    rts

; Fill ExRAM rows [m2_row, m2_end) with the M2 diagnostic pattern:
;   cols 0-27:  EX = (row & 3) << 6 | (col & 7)   (palette + bank sweep)
;   cols 28-31: EX = (row & 3) << 6               (bank 0; NT tiles 0-3 there)
; Works in mode %10 (blanked) or mode %01 (only while the PPU is rendering).
fill_exram_rows:
@row:
    lda m2_row
    cmp m2_end
    bcs @done
    ; m2_ptr = EXRAM + row*32
    sta m2_ptr
    lda #0
    sta m2_ptr+1
    .repeat 5
    asl m2_ptr
    rol m2_ptr+1
    .endrepeat
    lda m2_ptr+1
    clc
    adc #>EXRAM
    sta m2_ptr+1
    ; palette bits
    lda m2_row
    and #3
    tay
    lda pal_shift,y
    sta m2_palbits
    ldy #31
@col:
    cpy #28
    bcs @plain
    tya
    and #7
    ora m2_palbits
    bne @store
@plain:
    lda m2_palbits
@store:
    sta (m2_ptr),y
    dey
    bpl @col
    inc m2_row
    bne @row
@done:
    rts

pal_shift:
    .byte $00, $40, $80, $C0

; Palette upload + nametable init (rendering must be off)
ppu_init:
    bit $2002
    lda #$3F
    sta $2006
    lda #$00
    sta $2006
    ; BG palettes come from the generated texture data (tilegen derives the
    ; ramp from the actual texture colors).
    ldx #0
@pal:
    lda bg_palettes,x
    sta $2007
    inx
    cpx #16
    bne @pal
    ldx #0
@spal:
.ifdef E1M1
    lda sprite_palettes,x
.else
    lda palette_spr,x
.endif
    sta $2007
    inx
    cpx #16
    bne @spal
    ; clear NT0 + attributes (attributes unused in ExAttr mode)
    lda #$20
    sta $2006
    lda #$00
    sta $2006
    ldx #4
    ldy #0
    lda #0
@clrnt:
    sta $2007
    iny
    bne @clrnt
    dex
    bne @clrnt
.ifdef M2DEMO
    ; M2: cols 28-31 of view rows get tiles 0-3 (proves the NT byte still
    ; indexes within the ExAttr-selected bank)
    ldx #0              ; row
@ntvar:
    txa                 ; addr = $2000 + row*32 + 28
    sta m2_ptr
    lda #0
    sta m2_ptr+1
    .repeat 5
    asl m2_ptr
    rol m2_ptr+1
    .endrepeat
    lda m2_ptr
    clc
    adc #28
    sta m2_ptr
    lda m2_ptr+1
    adc #$20
    sta $2006
    lda m2_ptr
    sta $2006
    lda #0
    sta $2007
    lda #1
    sta $2007
    lda #2
    sta $2007
    lda #3
    sta $2007
    inx
    cpx #20
    bne @ntvar
.else
    ; status bar rows 20-24 ($2000 + 20*32 = $2280, 160 cells)
    lda #$22
    sta $2006
    lda #$80
    sta $2006
    ldx #0
.ifdef E1M1
@stnt:
    lda hud_nt,x        ; baked Doom status bar (tilegen build_hud)
    sta $2007
    inx
    cpx #160
    bne @stnt
.else
    lda #3
@stnt:
    sta $2007
    inx
    cpx #160
    bne @stnt
.endif
.endif
    ; park VRAM address away from the palette
    lda #$20
    sta $2006
    lda #$00
    sta $2006
    rts

palette_spr:
.ifdef E1M1
    .byte $0F, $00, $08, $27
.else
    .byte $0F, $30, $26, $05
.endif
    .byte $0F, $30, $2A, $1A
    .byte $0F, $30, $22, $12
    .byte $0F, $30, $17, $07

.segment "VECTORS"
    .word nmi_handler
    .word reset
    .word irq_handler
