-- M1: ROM boots, NMI counts frames, scanline IRQ fires near line 160,
-- ExRAM round-trips in mode %10, ZP canary intact.
local frames = 0
local irqScanlines = {}

local function fail(msg)
  print("M1 FAIL: " .. msg)
  emu.stop(1)
end

emu.addEventCallback(function()
  local ok, s = pcall(emu.getState)
  if ok and s and s["ppu.scanline"] then
    irqScanlines[#irqScanlines + 1] = s["ppu.scanline"]
  else
    irqScanlines[#irqScanlines + 1] = -1
  end
end, emu.eventType.irq)

emu.addEventCallback(function()
  frames = frames + 1
  if frames < 120 then return end

  local MT = emu.memType.nesDebug
  local fc     = emu.read(0x00, MT)
  local hb     = emu.read(0x08, MT)
  local irqc   = emu.read(0x09, MT)
  local ex     = emu.read(0x0A, MT)
  local canary = emu.read(0x8F, MT)
  print(string.format(
    "frame_cnt=%d heartbeat=%d irq_cnt=%d exram=%02X canary=%02X nIrq=%d",
    fc, hb, irqc, ex, canary, #irqScanlines))

  if fc < 100 then return fail("frame_cnt not advancing") end
  if ex ~= 0xA5 then return fail(string.format("ExRAM round-trip failed (%02X)", ex)) end
  if canary ~= 0xC5 then return fail("ZP canary clobbered") end
  if #irqScanlines < 100 then return fail("scanline IRQ not firing every frame") end

  -- skip the first few IRQs (stale pending flag can be serviced late after cli)
  local mn, mx = 999, -999
  for i = 5, #irqScanlines do
    local sl = irqScanlines[i]
    if sl >= 0 then
      if sl < mn then mn = sl end
      if sl > mx then mx = sl end
    end
  end
  print(string.format("irq scanline min=%d max=%d (excluding first 4)", mn, mx))
  if mx < 0 then return fail("no scanline data captured") end
  if mn < 160 or mx > 162 then
    return fail("IRQ scanline out of expected 160-162 range")
  end

  print("M1 PASS")
  emu.stop(0)
end, emu.eventType.endFrame)
