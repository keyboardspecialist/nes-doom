; MMC5 scanline IRQ.
;
; M2DEMO build: single IRQ at line 160; one-shot ExRAM fill in mode %01 while
; the PPU renders (proves render-time ExRAM writes land).
;
; M3+ build: two phases.
;   phase 0, line 160: status bar starts here (its tiles are static — nothing
;     to do); re-arm the comparator for line 207.
;   phase 1, line 207: spin to the end of the line, blank rendering ($2001=0)
;     -> 33-line letterbox, flip ExRAM to CPU-writable, run the letterbox
;     share of the band pusher. NMI restores everything.
.include "zeropage.inc"
.include "mmc5.inc"
.include "globals.inc"

.export irq_handler

.segment "FIXED"

.ifdef M2DEMO

.import fill_exram_rows

irq_handler:
    pha
    lda MMC5_IRQ_EN     ; read $5204 acknowledges the pending IRQ
    inc irq_cnt
    lda m2_fill_req
    beq @out
    txa
    pha
    tya
    pha
    lda #0
    sta m2_fill_req
    lda #10
    sta m2_row
    lda #20
    sta m2_end
    jsr fill_exram_rows
    pla
    tay
    pla
    tax
@out:
    pla
    rti

.else

.import push_run
.ifdef E1M1
.import hud_palettes
.endif

irq_handler:
    pha
    lda MMC5_IRQ_EN     ; ack
    inc irq_cnt
    lda irq_phase
    bne @phase1
    ; --- phase 0: line 160 (status bar split) ---
.ifdef E1M1
    ; Swap in the HUD palette set: blank rendering, stream 16 bytes into
    ; $3F00-$3F0F, restore mid-frame scroll, unblank. The writes sweep a
    ; visible color stripe while blanked (the "full palette" PPU quirk) —
    ; ~2 scanlines eaten from the top of the status bar, which the HUD art
    ; keeps black. The MMC5 scanline counter freezes while blanked, so the
    ; 199 compare fires correspondingly late; the letterbox stays wide
    ; enough for the push quota.
    txa
    pha
    lda #0
    sta $2001
    lda #%10001000      ; NMI on, increment-1 for palette writes
    sta $2000
    bit $2002
    lda #$3F
    sta $2006
    lda #$00
    sta $2006
    ldx #0
@hp: lda hud_palettes,x
    sta $2007
    inx
    cpx #16
    bne @hp
    lda #HUD_CHR_WINDOW
    sta MMC5_CHR_HI      ; ExAttr bank 61 now selects physical HUD bank 125
    ; mid-frame scroll re-establish: v = fineY 2, coarse Y 20 -> $2280
    bit $2002
    lda #$22
    sta $2006
    lda #$80
    sta $2006
    lda ppu2000_sh
    sta $2000
    lda #STATUS_MASK
    sta $2001           ; HUD uses BG only; weapon ends at line 159
    pla
    tax
    ; the mid-frame blank cleared MMC5 in-frame detection; the counter
    ; restarts from 0 when rendering resumes (~line 162), so phase 1 arms
    ; a RELATIVE compare measured to land the letterbox at line 199
    lda #SPLIT2_CMP
    sta MMC5_IRQ_CMP
    inc irq_phase
    pla
    rti
.else
    lda #BLANK_LINE
    sta MMC5_IRQ_CMP
    inc irq_phase
    pla
    rti
.endif
@phase1:
    ; --- phase 1: line 199 (letterbox + push) ---
    ; Last IRQ of the frame. Disable the scanline IRQ: blanking freezes the
    ; MMC5 scanline counter at the compare value, which would otherwise keep
    ; re-asserting pending after every ack (IRQ storm). NMI re-enables it.
    lda #0
    sta MMC5_IRQ_EN
    txa
    pha
    tya
    pha
    ; IRQ is raised at PPU dot ~4; with service latency + entry we are ~30 CPU
    ; cycles in. Spin out most of the rest of line 199 so the blank lands near
    ; the 199/200 boundary (glitch confined to the letterbox seam).
    ldx #11
@spin:
    dex
    bne @spin
    lda #%00001100      ; exclude NMI before entering transient PPU/ExRAM state
    sta $2000
    lda #0
    sta $2001           ; letterbox begins
    lda #EXRAM_MODE_RAM
    sta MMC5_EXRAM_MODE
    lda #IRQ_QUOTA
    sta push_quota
    jsr push_run
    lda #%10001100      ; NMI on, preserve inc-32 until the handler restores it
    sta $2000
    pla
    tay
    pla
    tax
    pla
    rti

.endif
