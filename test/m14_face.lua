-- M14: fixed face palette, damage-tier reactions, timer refresh, idle, death.
local frames = 0
local MT = nil
local ppuAddrHi, ppuAddr, ppuInc = nil, nil, 1
local activeRun = nil
local faceRuns = {}
local badTiming = false
local targets = {
  [0x22AE] = 4, [0x22CE] = 4, [0x22EE] = 4, [0x230E] = 4,
}

local function fail(msg)
  print("M14 FAIL: " .. msg)
  emu.stop(1)
end

local function same(run, expected)
  if not run or #run ~= #expected then return false end
  for i = 1, #expected do
    if run[i] ~= expected[i] then return false end
  end
  return true
end

emu.addEventCallback(function()
  emu.setInput({start = frames < 10}, 0)
end, emu.eventType.inputPolled)

pcall(function()
  emu.addMemoryCallback(function(_addr, value)
    ppuInc = math.floor(value / 4) % 2 == 1 and 32 or 1
  end, emu.callbackType.write, 0x2000)
  emu.addMemoryCallback(function(_addr, value)
    if ppuAddrHi == nil then
      ppuAddrHi = value
    else
      ppuAddr = (ppuAddrHi % 0x40) * 256 + value
      ppuAddrHi = nil
      activeRun = nil
    end
  end, emu.callbackType.write, 0x2006)
  emu.addMemoryCallback(function(_addr, value)
    if frames >= 80 and ppuAddr then
      if not activeRun and targets[ppuAddr] then
        activeRun = {address = ppuAddr, left = 4, values = {}}
      end
      if activeRun then
        table.insert(activeRun.values, value)
        activeRun.left = activeRun.left - 1
        local line = emu.getState()["ppu.scanline"]
        if line < 241 or line > 260 then badTiming = true end
        if activeRun.left == 0 then
          faceRuns[activeRun.address] = activeRun.values
          activeRun = nil
        end
      end
      ppuAddr = (ppuAddr + ppuInc) % 0x4000
    end
  end, emu.callbackType.write, 0x2007)
end)

emu.addEventCallback(function()
  frames = frames + 1
  MT = emu.memType.nesDebug

  if frames == 100 then
    -- Face rectangle is rows 21-24, columns 14-17 in ExRAM.
    for row = 0, 3 do
      for col = 0, 3 do
        local ex = emu.read(0x5C00 + (21 + row) * 32 + 14 + col, MT)
        if ex ~= 0xBF then return fail(string.format("face ExAttr=%02X", ex)) end
      end
    end
    emu.write(0x6A05, 79, MT) -- tier 1
    emu.write(0x6A28, 1, MT)
    emu.write(0x6AFD, 1, MT)  -- committed damage event
  elseif frames == 120 then
    if emu.read(0x6A10, MT) ~= 6 or emu.read(0x6A11, MT) ~= 6 then
      return fail("tier-1 damage face was not displayed")
    end
    if not same(faceRuns[0x22AE], {0x60, 0x61, 0x62, 0x63}) or
       not same(faceRuns[0x230E], {0x6C, 0x6D, 0x6E, 0x6F}) then
      return fail("tier-1 face tile runs incorrect")
    end
    emu.write(0x6A05, 39, MT) -- tier 3, refresh pain timer
    emu.write(0x6A28, 1, MT)
    emu.write(0x6AFD, 2, MT)
  elseif frames == 145 then
    if emu.read(0x6A10, MT) ~= 8 or emu.read(0x6A11, MT) ~= 8 then
      return fail("second hit did not select tier-3 damage face")
    end
    if emu.read(0x6A12, MT) < 30 then return fail("damage timer was not refreshed") end
  elseif frames == 210 then
    if emu.read(0x6A10, MT) ~= 3 or emu.read(0x6A11, MT) ~= 3 then
      return fail("pain face did not return to tier-3 idle")
    end
    emu.write(0x6A05, 0, MT)
    emu.write(0x6A28, 1, MT)
    emu.write(0x6AFD, 3, MT)
  elseif frames == 230 then
    if emu.read(0x6A10, MT) ~= 12 or emu.read(0x6A11, MT) ~= 12 then
      return fail("death face was not displayed")
    end
    if not same(faceRuns[0x22AE], {0xC0, 0xC1, 0xC2, 0xC3}) then
      return fail("death face tile run incorrect")
    end
    emu.write(0x6AFD, 4, MT) -- post-death attacks cannot replace death
  elseif frames == 250 then
    if emu.read(0x6A10, MT) ~= 12 or emu.read(0x6A11, MT) ~= 12 then
      return fail("post-death hit replaced death face")
    end
    -- Debug-revive to cover healthy-tier pain expiry independently.
    emu.write(0x6A05, 100, MT)
    emu.write(0x6A28, 1, MT)
    emu.write(0x6AFD, 5, MT)
  elseif frames == 270 then
    if emu.read(0x6A10, MT) ~= 5 or emu.read(0x6A11, MT) ~= 5 then
      return fail("healthy damage face was not displayed")
    end
  elseif frames == 335 then
    if emu.read(0x6A10, MT) ~= 0 or emu.read(0x6A11, MT) ~= 0 then
      return fail("healthy pain did not return directly to centered idle")
    end
    if badTiming then return fail("face VRAM write occurred outside vblank") end
    if emu.read(0x8F, MT) ~= 0xC5 then return fail("ZP canary clobbered") end
    print("M14 PASS (palette, pain tiers, refresh, idle, death)")
    emu.stop(0)
  end
end, emu.eventType.endFrame)
