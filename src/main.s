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
.import hud_nt, hud_ex, sec_pal, weapon_oam
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

@vwait2:
    bit $2002
    bpl @vwait2

    jsr mmc5_init
    jsr exram_selftest  ; leaves ExRAM zeroed, mode %10

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
.endif
    mmc5_exram_attr_mode

    jsr ppu_init

.ifdef E1M1
    ; Static weapon OAM.  The rest of the page was initialized to $FF above,
    ; so all unused sprite records remain hidden.
    ldx #0
@weapon_oam:
    lda weapon_oam,x
    sta $0200,x
    inx
    cpx #144
    bne @weapon_oam
    lda #0
    sta $2003
    lda #$02
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
    lda #%10001000      ; NMI on, 8x8 sprites at $1000, BG $0000, VRAM inc +1
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
    sta MMC5_CHR_HI
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
    ; sprite CHR banks 0-7 (1KB mode)
    ldx #7
@sprbanks:
    txa
    sta MMC5_CHR_SPR0,x
    dex
    bpl @sprbanks
.ifdef E1M1
    ; 8x8 sprites use pattern table $1000: map its four 1KB pages to bank 63.
    lda #WEAPON_BANK * 4
    sta MMC5_CHR_SPR0+4
    lda #WEAPON_BANK * 4 + 1
    sta MMC5_CHR_SPR0+5
    lda #WEAPON_BANK * 4 + 2
    sta MMC5_CHR_SPR0+6
    lda #WEAPON_BANK * 4 + 3
    sta MMC5_CHR_SPR0+7
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
    ; ramp from the actual texture colors); sprite palettes are static
    ldx #0
@pal:
    lda bg_palettes,x
    sta $2007
    inx
    cpx #16
    bne @pal
    ldx #0
@spal:
    lda palette_spr,x
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
