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

irq_handler:
    pha
    lda MMC5_IRQ_EN     ; ack
    inc irq_cnt
    lda irq_phase
    bne @phase1
    ; --- phase 0: line 160 (status bar split) ---
    lda #BLANK_LINE
    sta MMC5_IRQ_CMP
    inc irq_phase
    pla
    rti
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
    ldx #12
@spin:
    dex
    bne @spin
    lda #0
    sta $2001           ; letterbox begins
    lda #EXRAM_MODE_RAM
    sta MMC5_EXRAM_MODE
    lda #%10001100      ; inc-32 for column pushes
    sta $2000
    lda #IRQ_QUOTA
    sta push_quota
    jsr push_run
    pla
    tay
    pla
    tax
    pla
    rti

.endif
