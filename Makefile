CA65  := ca65
LD65  := ld65
PY    := python3
MESEN := /Applications/Mesen.app/Contents/MacOS/Mesen
WAD   := Doom1.WAD
export PYTHONDONTWRITEBYTECODE := 1

ROM      := nesdoom.nes
ROM_M2   := nesdoom-m2.nes
ROM_E1M1 := nesdoom-e1m1.nes
ROM_FULL := nesdoom-e1m1-full.nes
SRCS   := header main title nmi irq vram_push math render bsp enemy door hud audio chr
GENS   := tables luts map
OBJS   := $(addprefix obj/,$(addsuffix .o,$(SRCS) $(GENS)))
OBJSM2 := $(addprefix obj-m2/,$(addsuffix .o,$(SRCS) $(GENS)))
OBJSE1 := $(addprefix obj-e1m1/,$(addsuffix .o,$(SRCS) $(GENS) music_data))
OBJSFULL := $(addprefix obj-e1m1-full/,$(addsuffix .o,$(SRCS) $(GENS) music_data))
INCS   := src/zeropage.inc src/mmc5.inc src/globals.inc

.PHONY: all clean e1m1 e1m1-full test test-python test-m1 test-m2 test-m3 test-m4 test-m5 test-m6 test-m7 test-m8 test-m9 test-m10 test-m11 test-m12 test-m13 test-m14 test-m15 test-e1m1 test-e1m1-full

all: $(ROM) $(ROM_M2)

e1m1: $(ROM_E1M1)
e1m1-full: $(ROM_FULL)

$(ROM): $(OBJS) cfg/nesdoom.cfg
	$(LD65) -C cfg/nesdoom.cfg -o $@ --dbgfile nesdoom.dbg $(OBJS)

$(ROM_M2): $(OBJSM2) cfg/nesdoom.cfg
	$(LD65) -C cfg/nesdoom.cfg -o $@ --dbgfile nesdoom-m2.dbg $(OBJSM2)

$(ROM_E1M1): $(OBJSE1) cfg/nesdoom.cfg
	$(LD65) -C cfg/nesdoom.cfg -o $@ --dbgfile nesdoom-e1m1.dbg $(OBJSE1)

$(ROM_FULL): $(OBJSFULL) cfg/nesdoom.cfg
	$(LD65) -C cfg/nesdoom.cfg -o $@ --dbgfile nesdoom-e1m1-full.dbg $(OBJSFULL)

obj/%.o: src/%.s $(INCS) | obj
	$(CA65) -g -o $@ $<

obj-m2/%.o: src/%.s $(INCS) | obj-m2
	$(CA65) -g -D M2DEMO -o $@ $<

obj-e1m1/%.o: src/%.s $(INCS) | obj-e1m1
	$(CA65) -g -D E1M1 -o $@ $<

obj-e1m1-full/%.o: src/%.s $(INCS) | obj-e1m1-full
	$(CA65) -g -D E1M1 -D FULL_E1M1 -o $@ $<

obj/%.o: assets/build/%.s | obj
	$(CA65) -g -o $@ $<

obj-m2/%.o: assets/build/%.s | obj-m2
	$(CA65) -g -D M2DEMO -o $@ $<

obj-e1m1/map.o: assets/build/e1m1-map.s | obj-e1m1
	$(CA65) -g -D E1M1 -o $@ $<

obj-e1m1/luts.o: assets/build/e1m1-luts.s | obj-e1m1
	$(CA65) -g -D E1M1 -o $@ $<

obj-e1m1/tables.o: assets/build/tables.s | obj-e1m1
	$(CA65) -g -D E1M1 -o $@ $<

obj-e1m1/music_data.o: assets/build/e1m1-music.s | obj-e1m1
	$(CA65) -g -D E1M1 -o $@ $<

obj-e1m1-full/map.o: assets/build/e1m1-full-map.s | obj-e1m1-full
	$(CA65) -g -D E1M1 -D FULL_E1M1 -o $@ $<

obj-e1m1-full/luts.o: assets/build/e1m1-full-luts.s | obj-e1m1-full
	$(CA65) -g -D E1M1 -D FULL_E1M1 -o $@ $<

obj-e1m1-full/tables.o: assets/build/tables.s | obj-e1m1-full
	$(CA65) -g -D E1M1 -D FULL_E1M1 -o $@ $<

obj-e1m1-full/music_data.o: assets/build/e1m1-music.s | obj-e1m1-full
	$(CA65) -g -D E1M1 -D FULL_E1M1 -o $@ $<

obj/chr.o obj-m2/chr.o: assets/build/chr-game.bin assets/build/chr-test.bin
obj-e1m1/chr.o: assets/build/chr-e1m1.bin
obj-e1m1-full/chr.o: assets/build/chr-e1m1-full.bin

obj obj-m2 obj-e1m1 obj-e1m1-full:
	mkdir -p $@

assets/build/chr-test.bin: tools/tilegen.py | assets/build
	$(PY) tools/tilegen.py --test -o $@

assets/build/chr-game.bin assets/build/luts.s: tools/tilegen.py | assets/build
	$(PY) tools/tilegen.py --game -o assets/build/chr-game.bin --luts assets/build/luts.s

assets/build/tables.s: tools/tablegen.py | assets/build
	$(PY) tools/tablegen.py -o $@

assets/build/map.s: tools/mapconv.py | assets/build
	$(PY) tools/mapconv.py -o $@

assets/build/e1m1-map.s assets/build/texlist.json: tools/mapconv.py tools/wadlib.py $(WAD) | assets/build
	$(PY) tools/mapconv.py --wad $(WAD) --map E1M1 --texlist assets/build/texlist.json -o assets/build/e1m1-map.s

assets/build/e1m1-full-map.s assets/build/texlist-full.json: tools/mapconv.py tools/wadlib.py $(WAD) | assets/build
	$(PY) tools/mapconv.py --wad $(WAD) --map E1M1 --full \
	    --texlist assets/build/texlist-full.json -o assets/build/e1m1-full-map.s

assets/build/e1m1-music.s: tools/musicgen.py tools/wadlib.py $(WAD) | assets/build
	$(PY) tools/musicgen.py --wad $(WAD) --lump D_E1M1 -o $@

assets/build/chr-e1m1.bin assets/build/e1m1-luts.s: tools/tilegen.py tools/wadlib.py assets/build/texlist.json $(WAD)
	$(PY) tools/tilegen.py --wad $(WAD) --texlist assets/build/texlist.json \
	    -o assets/build/chr-e1m1.bin --luts assets/build/e1m1-luts.s

assets/build/chr-e1m1-full.bin assets/build/e1m1-full-luts.s: tools/tilegen.py tools/wadlib.py assets/build/texlist-full.json $(WAD)
	$(PY) tools/tilegen.py --wad $(WAD) --texlist assets/build/texlist-full.json \
	    -o assets/build/chr-e1m1-full.bin --luts assets/build/e1m1-full-luts.s

assets/build:
	mkdir -p assets/build

test: test-python test-m1 test-m2 test-m3 test-m4 test-m5 test-m12

ifneq ($(wildcard $(WAD)),)
test: test-e1m1 test-e1m1-full test-m6 test-m7 test-m8 test-m9 test-m10 test-m11 test-m13 test-m14 test-m15
endif

test-python:
	PYTHONDONTWRITEBYTECODE=1 $(PY) -m unittest discover -s test -p 'test_*.py'

test-m1: $(ROM_M2)
	sh test/run_mesen.sh $(ROM_M2) test/m1_boot.lua

test-m2: $(ROM_M2)
	sh test/run_mesen.sh $(ROM_M2) test/m2_exattr.lua

test-m3: $(ROM)
	sh test/run_mesen.sh $(ROM) test/m3_bandwidth.lua

test-m4: $(ROM)
	sh test/run_mesen.sh $(ROM) test/m4_wall.lua

test-m5: $(ROM)
	sh test/run_mesen.sh $(ROM) test/m5_bsp.lua

test-m12: $(ROM)
	sh test/run_mesen.sh $(ROM) test/m12_collision.lua

test-m13: $(ROM_FULL)
	sh test/run_mesen.sh $(ROM_FULL) test/m13_door.lua

test-m14: $(ROM_E1M1)
	sh test/run_mesen.sh $(ROM_E1M1) test/m14_face.lua

test-m15: $(ROM_FULL)
	sh test/run_mesen.sh $(ROM_FULL) test/m15_world.lua

test-e1m1: $(ROM_E1M1)
	sh test/run_mesen.sh $(ROM_E1M1) test/e1m1.lua

test-e1m1-full: $(ROM_FULL)
	sh test/run_mesen.sh $(ROM_FULL) test/e1m1_full.lua

test-m6: $(ROM_E1M1)
	sh test/run_mesen.sh $(ROM_E1M1) test/m6_weapon.lua

test-m7: $(ROM_E1M1)
	sh test/run_mesen.sh $(ROM_E1M1) test/m7_gameplay.lua

test-m8: $(ROM_E1M1)
	sh test/run_mesen.sh $(ROM_E1M1) test/m8_combat.lua

test-m9: $(ROM_FULL)
	sh test/run_mesen.sh $(ROM_FULL) test/m9_enemy.lua

test-m10: $(ROM_E1M1)
	sh test/run_mesen.sh $(ROM_E1M1) test/m10_title.lua

test-m11: $(ROM_E1M1)
	sh test/run_mesen.sh $(ROM_E1M1) test/m11_music.lua

clean:
	rm -rf obj obj-m2 obj-e1m1 assets/build \
	    obj-e1m1-full $(ROM) $(ROM_M2) $(ROM_E1M1) $(ROM_FULL) \
	    nesdoom.dbg nesdoom-m2.dbg nesdoom-e1m1.dbg nesdoom-e1m1-full.dbg
