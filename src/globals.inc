; Shared constants: compose buffers, pusher banks, push quotas.
.ifndef GLOBALS_INC
GLOBALS_INC = 1

; Double-buffered compose shadows in PRG-RAM (column-major: [col*20 + row]).
; Fixed addresses because the unrolled pushers bake them into absolute operands.
BUFA_NT = $6000     ; 640 bytes
BUFA_EX = $6280     ; 640 bytes
BUFB_NT = $6500
BUFB_EX = $6780
; Camera-sector palette metadata travels with each compose buffer.  The
; pusher publishes it only after the final column reaches the nametable.
BUFA_PAL_SEC = $6A00
BUFA_OAM_SET = $6A02  ; one four-page set base byte per compose buffer
PL_AMMO = $6A04
PL_HEALTH = $6A05
PL_ARMOR = $6A06
PL_ARMOR_TYPE = $6A07
THING_ACTIVE = $6A08  ; 8-byte active bitset, through $6A0F
FACE_WANT = $6A10
FACE_SHOWN = $6A11
FACE_TIMER = $6A12
FACE_HIT_SEEN = $6A13
FACE_IDLE_TIMER = $6A14
FACE_IDLE_PHASE = $6A15
LEVEL_COMPLETE = $6A16
PICKUP_SOUND_PENDING = $6A17
PLAYER_PAIN_SOUND_PENDING = $6A18
DOOR_SOUND_PENDING = $6A19
EXIT_SOUND_PENDING = $6A1A
PLAYER_PREV_X = $6A1B
PLAYER_PREV_Y = $6A1D
HUD_DIRTY = $6A28
WEAPON_FRAME = $6A29
WEAPON_TIMER = $6A2A
SHOT_COUNT = $6A2B
PICKUP_COUNT = $6A2C
MAX_THINGS = 64
MAX_MONSTERS = 8
THING_HEALTH = $6A2D       ; 64 bytes, through $6A6C
THING_DEATH_AT = $6A6D     ; 64 bytes, through $6AAC
SHOT_SEEN = $6AAD
SHOT_PENDING = $6AAE
SHOT_TARGET = $6AAF
SHOT_BEST_LO = $6AB0
SHOT_BEST_HI = $6AB1
HIT_COUNT = $6AB2
BARREL_KILLS = $6AB3
EXPLOSION_SOUND_PENDING = $6AB4
BUFA_EXPLOSION_SOUND = $6AB5 ; frame-owned flags, one per compose buffer
EXPLOSION_RENDER_COUNT = $6AB7
THING_EXP_SOUND_SENT = $6AB8 ; 8-byte bitset for MAX_THINGS
FULL_SEG1_SEEN = $6AC0
FULL_HIGH_VERTEX_SEEN = $6AC1
MONSTER_X_LO = $6AC2          ; 8 bytes each
MONSTER_X_HI = $6ACA
MONSTER_Y_LO = $6AD2
MONSTER_Y_HI = $6ADA
MONSTER_SS = $6AE2
MONSTER_LAST_MOVE = $6AEA
MONSTER_LAST_ATTACK = $6AF2
ENEMY_SOUND_PENDING = $6AFA
ZOMBIE_KILLS = $6AFB
ENEMY_ATTACKS = $6AFC
ENEMY_HITS = $6AFD
EXPLOSION_OAM_COUNT = $6AFE
; Three-set rotation: front/back compose ownership plus one stable DMA set.
; Each set has one page per generated weapon frame.
OAMA = $6B00
OAMB = $6F00
OAMC = $7300
; Dynamic map state. Door ceilings are indexed directly by sector byte.
SECTOR_CEIL_RT = $7700      ; 256-byte mutable ceiling shadow
SECTOR_FLOOR_RT = $7900     ; 256-byte mutable floor shadow
DOOR_POS = $7800            ; 8 bytes: rise above closed ceiling
DOOR_STATE = $7808          ; 0 closed, 1 opening, 2 waiting, 3 closing
DOOR_PHASE = $7810          ; half-speed fractional accumulator
DOOR_WAIT = $7818           ; open hold countdown in video frames
DOOR_PASSABLE = $7820       ; collision gate, one byte per door
DOOR_LAST_FRAME = $7828
DOOR_ELAPSED = $7829
DOOR_BEST_ID = $782A
DOOR_BEST_LO = $782B
DOOR_BEST_HI = $782C
DOOR_USE_INDEX = $782D
LIFT_STATE = $782E          ; 0 top, 1 lowering, 2 waiting, 3 raising
LIFT_POS = $782F            ; distance below the high floor
LIFT_PHASE = $7830          ; quarter-speed fractional accumulator
LIFT_WAIT = $7831
LIFT_LAST_FRAME = $7832

; Pusher code banks (PRG02/PRG03 mapped at $8000 via $5114; bit7 = ROM)
PUSH_BANK_A = $82
PUSH_BANK_B = $83
PUSH_JMP    = $8000     ; 32 x 3-byte JMP dispatch at the start of each pusher bank

MAP_COMMON_BANK = $81   ; $A000 window in the untrimmed E1M1 build
MAP_SEG0_BANK = $84
MAP_SEG1_BANK = $85
MAP_GEOM_BANK = $86
DOOR_CODE_BANK = $8D
HUD_CODE_BANK = $89

; Screen split: view rows 0-19 (lines 0-159), status bar rows 20-24 (lines
; 160-199), letterbox lines 200-240. A column costs ~410 cycles including
; driver dispatch (measured the hard way: 9 columns + overhead exactly filled
; the old 207-241 window and collided with NMI).
;   letterbox window: IRQ@199 -> NMI@241 = 42 lines ~ 4775 cycles;
;     entry ~130 + 10x410 + exit ~15 = 4245, ends ~line 236 (5-line margin)
;   E1M1 normal vblank: entry/input ~130 + OAM DMA ~520 + 2x410
;     + palette/restore ~350 = ~1820 of 2273. A HUD upload reduces the quota
;     to zero columns for that frame.
STATUS_LINE = 160
BLANK_LINE  = 199
VIEW_MASK   = %00011110  ; BG + sprites in the 160-line view
STATUS_MASK = %00001110  ; BG only below the view
SPLIT2_CMP  = 35    ; E1M1: phase-1 compare RELATIVE to the counter restart
                    ; after the line-160 palette-swap blank (measured)
IRQ_QUOTA = 10
.ifdef E1M1
NMI_QUOTA = 2       ; vblank also loads the per-sector palette set (~210 cyc)
.else
NMI_QUOTA = 3
.endif

VIEW_ROWS = 20
VIEW_COLS = 32
PF_CLIP   = 36      ; angle-gate clip half-angle: 32 (45 deg) + atan slack;
                    ; must match the angcol_tbl domain in tools/tablegen.py

; CHR bank layout (must match tools/tilegen.py): variable banks for WAD
; textures, six banks per synthetic texture, then the flats/status bank.
.ifdef E1M1
FLAT_BANK = 60      ; WAD textures fill banks 0-59 (variable banks/texture)
EDGE_BANK = 62      ; 128 sloped silhouette tiles (HUD sits at 61)
SPRITE_CHR_PAGE = 256 ; first of eight 1KB 8x16 sprite pages
WORLD_SPRITE_PAGE_COUNT = 6
WEAPON_SPRITE_PAGE_FIRST = 6
HUD_CHR_WINDOW = 1  ; line-160 split: low ExAttr bank 61 -> physical bank 125
HUD_FACE_BANK = 63  ; window 1 -> physical bank 127
TITLE_CHR_WINDOW = 2 ; title banks 128-130, selected before gameplay starts
TITLE_PRG_BANK = $87
MUSIC_PRG_BANK = $88

; Audio state uses the unused tail of PRG-RAM. It is fixed-address so Mesen
; timing tests can inspect playback without depending on linker symbols.
MUSIC_DELAY = $7F00
MUSIC_PTR_LO = $7F01
MUSIC_PTR_HI = $7F02
MUSIC_SKIP_COUNT = $7F03
MUSIC_LOOP_COUNT = $7F04
PISTOL_SOUND_PENDING = $7F05
NOISE_HOLD = $7F06
AUDIO_MASK = $7F07
AUDIO_CMD = $7F08
AUDIO_SAVE_PTR = $7F09
AUDIO_P0_HI = $7F0B
AUDIO_P1_HI = $7F0C
AUDIO_M0_HI = $7F0D
AUDIO_M1_HI = $7F0E
AUDIO_DESIRED_HI = $7F0F
MUSIC_EVENT_COUNT = $7F10
EMPTY_SOUND_PENDING = $7F11
NOISE_OWNER = $7F12
.else
FLAT_BANK = 12      ; 2 synthetic textures, 6 banks each
.endif
SLICES_PER_TEX = 109    ; sum of per-class phase counts

.endif
