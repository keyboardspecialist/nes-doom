; MMC5 register definitions — https://www.nesdev.org/wiki/MMC5
.ifndef MMC5_INC
MMC5_INC = 1

MMC5_PRG_MODE   = $5100     ; 0=32K 1=16K 2=16K+8K 3=4x8K
MMC5_CHR_MODE   = $5101     ; 0=8K 1=4K 2=2K 3=1K (ignored for BG in ExAttr mode)
MMC5_RAM_PROT1  = $5102     ; write $02 ..
MMC5_RAM_PROT2  = $5103     ; .. and $01 to enable PRG-RAM writes
MMC5_EXRAM_MODE = $5104     ; %00/%01 NT/ExAttr (CPU-writable only during rendering)
                            ; %10 ordinary RAM, %11 read-only
MMC5_NT_MAP     = $5105     ; 2 bits per logical NT: 0/1=CIRAM 2=ExRAM 3=fill
MMC5_FILL_TILE  = $5106
MMC5_FILL_ATTR  = $5107
MMC5_RAM_BANK   = $5113     ; PRG-RAM bank at $6000
MMC5_PRG_8000   = $5114     ; bit7=1 selects ROM (else PRG-RAM)
MMC5_PRG_A000   = $5115
MMC5_PRG_C000   = $5116
MMC5_PRG_E000   = $5117     ; always ROM; power-on = last bank
MMC5_CHR_SPR0   = $5120     ; sprite banks ($5120-$5127)
MMC5_CHR_BG0    = $5128     ; BG banks in 8x16 mode ($5128-$512B)
MMC5_CHR_HI     = $5130     ; upper 2 CHR bits (global; pages the 256KB window)
MMC5_SPLIT_CTRL = $5200
MMC5_SPLIT_SCRL = $5201
MMC5_SPLIT_BANK = $5202
MMC5_IRQ_CMP    = $5203     ; target scanline ($00 never fires)
MMC5_IRQ_EN     = $5204     ; write bit7=enable; read: bit7 pending (read acks), bit6 in-frame
MMC5_MULT_A     = $5205     ; unsigned 8x8 -> 16, result readable immediately
MMC5_MULT_B     = $5206     ; write B here; read $5205=lo $5206=hi
EXRAM           = $5C00     ; 1KB

MMC5_PULSE1_CTRL = $5000
MMC5_PULSE1_LO   = $5002
MMC5_PULSE1_HI   = $5003
MMC5_PULSE2_CTRL = $5004
MMC5_PULSE2_LO   = $5006
MMC5_PULSE2_HI   = $5007
MMC5_PCM_CTRL    = $5010
MMC5_PCM_DATA    = $5011
MMC5_AUDIO_EN    = $5015

EXRAM_MODE_EXATTR = %01
EXRAM_MODE_RAM    = %10

; Flip ExRAM to CPU-writable (call only while PPU is blanked; restore before render)
.macro mmc5_exram_cpu_mode
    lda #EXRAM_MODE_RAM
    sta MMC5_EXRAM_MODE
.endmacro

.macro mmc5_exram_attr_mode
    lda #EXRAM_MODE_EXATTR
    sta MMC5_EXRAM_MODE
.endmacro

.endif
