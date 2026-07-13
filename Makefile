CA65  := ca65
LD65  := ld65
PY    := python3
MESEN := /Applications/Mesen.app/Contents/MacOS/Mesen
WAD   := Doom1.WAD

ROM      := nesdoom.nes
ROM_M2   := nesdoom-m2.nes
ROM_E1M1 := nesdoom-e1m1.nes
SRCS   := header main nmi irq vram_push math render bsp chr
GENS   := tables luts map
OBJS   := $(addprefix obj/,$(addsuffix .o,$(SRCS) $(GENS)))
OBJSM2 := $(addprefix obj-m2/,$(addsuffix .o,$(SRCS) $(GENS)))
OBJSE1 := $(addprefix obj-e1m1/,$(addsuffix .o,$(SRCS) $(GENS)))
INCS   := src/zeropage.inc src/mmc5.inc src/globals.inc

.PHONY: all clean test test-m1 test-m2 test-m3 test-m4 test-m5 test-e1m1

all: $(ROM) $(ROM_M2)

e1m1: $(ROM_E1M1)

$(ROM): $(OBJS) cfg/nesdoom.cfg
	$(LD65) -C cfg/nesdoom.cfg -o $@ --dbgfile nesdoom.dbg $(OBJS)

$(ROM_M2): $(OBJSM2) cfg/nesdoom.cfg
	$(LD65) -C cfg/nesdoom.cfg -o $@ --dbgfile nesdoom-m2.dbg $(OBJSM2)

$(ROM_E1M1): $(OBJSE1) cfg/nesdoom.cfg
	$(LD65) -C cfg/nesdoom.cfg -o $@ --dbgfile nesdoom-e1m1.dbg $(OBJSE1)

obj/%.o: src/%.s $(INCS) | obj
	$(CA65) -g -o $@ $<

obj-m2/%.o: src/%.s $(INCS) | obj-m2
	$(CA65) -g -D M2DEMO -o $@ $<

obj-e1m1/%.o: src/%.s $(INCS) | obj-e1m1
	$(CA65) -g -D E1M1 -o $@ $<

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

obj/chr.o obj-m2/chr.o: assets/build/chr-game.bin assets/build/chr-test.bin
obj-e1m1/chr.o: assets/build/chr-e1m1.bin

obj obj-m2 obj-e1m1:
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

assets/build/chr-e1m1.bin assets/build/e1m1-luts.s: tools/tilegen.py tools/wadlib.py assets/build/texlist.json
	$(PY) tools/tilegen.py --wad $(WAD) --texlist assets/build/texlist.json \
	    -o assets/build/chr-e1m1.bin --luts assets/build/e1m1-luts.s

assets/build:
	mkdir -p assets/build

test: test-m1 test-m2 test-m3 test-m4 test-m5

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

test-e1m1: $(ROM_E1M1)
	sh test/run_mesen.sh $(ROM_E1M1) test/e1m1.lua

clean:
	rm -rf obj obj-m2 obj-e1m1 assets/build \
	    $(ROM) $(ROM_M2) $(ROM_E1M1) nesdoom.dbg nesdoom-m2.dbg nesdoom-e1m1.dbg
