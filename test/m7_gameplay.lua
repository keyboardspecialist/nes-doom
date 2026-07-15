-- M7: NMI-polled pistol, dynamic HUD, and persistent pickup behavior.
local frames, polls = 0, 0
local MT = nil
local weaponSeen = {}
local hudRuns = {}
local hudBadTiming = false
local viewRestoreMax, viewRestoreBad, viewRestoreBadLine = -1, false, nil
local shotSounds = 0
local ppuAddrHi, ppuAddr, ppuInc = nil, nil, 1
local activeRun = nil
local targets = {
  [0x22A2] = 3, [0x22C2] = 3,
  [0x22A6] = 4, [0x22C6] = 4,
  [0x22B4] = 4, [0x22D4] = 4,
}

local function fail(msg)
  print("M7 FAIL: " .. msg)
  emu.stop(1)
end

local function teleport(x, y)
  emu.write(0x30, x % 256, MT)
  emu.write(0x31, math.floor(x / 256), MT)
  emu.write(0x32, y % 256, MT)
  emu.write(0x33, math.floor(y / 256), MT)
end

local function active(index)
  local value = emu.read(0x6A08 + math.floor(index / 8), MT)
  return math.floor(value / (2 ^ (index % 8))) % 2 == 1
end

local function same(run, expected)
  if not run or #run ~= #expected then return false end
  for i = 1, #expected do
    if run[i] ~= expected[i] then return false end
  end
  return true
end

emu.addEventCallback(function()
  polls = polls + 1
  emu.setInput({start = frames < 10, a = frames == 60}, 0) -- exactly one NMI poll
end, emu.eventType.inputPolled)

pcall(function()
  emu.addMemoryCallback(function(addr, value)
    if frames >= 50 then shotSounds = shotSounds + 1 end
  end, emu.callbackType.write, 0x400F)
  emu.addMemoryCallback(function(addr, value)
    if frames >= 50 and value == 0x1E then
      local line = emu.getState()["ppu.scanline"]
      if line > viewRestoreMax then viewRestoreMax = line end
      if line < 241 or line > 260 then
        viewRestoreBad = true
        viewRestoreBadLine = line
      end
    end
  end, emu.callbackType.write, 0x2001)
  emu.addMemoryCallback(function(addr, value)
    ppuInc = math.floor(value / 4) % 2 == 1 and 32 or 1
  end, emu.callbackType.write, 0x2000)
  emu.addMemoryCallback(function(addr, value)
    if ppuAddrHi == nil then
      ppuAddrHi = value
    else
      ppuAddr = (ppuAddrHi % 0x40) * 256 + value
      ppuAddrHi = nil
      activeRun = nil
    end
  end, emu.callbackType.write, 0x2006)
  emu.addMemoryCallback(function(addr, value)
    if frames >= 50 and ppuAddr then
      if not activeRun and targets[ppuAddr] then
        activeRun = { address = ppuAddr, left = targets[ppuAddr], values = {} }
      end
      if activeRun then
        table.insert(activeRun.values, value)
        activeRun.left = activeRun.left - 1
        local line = emu.getState()["ppu.scanline"]
        if line < 241 or line > 260 then hudBadTiming = true end
        if activeRun.left == 0 then
          hudRuns[activeRun.address] = activeRun.values
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
  local weaponFrame = emu.read(0x6A29, MT)
  if weaponFrame ~= 0 then weaponSeen[weaponFrame] = true end

  if frames == 120 then
    if polls < 100 then return fail("controller was not polled every frame") end
    if emu.read(0x6A2B, MT) ~= 1 or emu.read(0x6A04, MT) ~= 49 then
      return fail("brief A press did not consume exactly one round")
    end
    if shotSounds ~= 1 then return fail("shot did not trigger one noise report") end
    if not weaponSeen[1] or not weaponSeen[2] or not weaponSeen[3] then
      return fail("weapon animation did not visit all non-idle frames")
    end
    if weaponFrame ~= 0 or emu.read(0x6A2A, MT) ~= 0 then
      return fail("weapon did not return to idle")
    end
    if not same(hudRuns[0x22A2], {0x00, 0x76, 0x80}) or
       not same(hudRuns[0x22C2], {0x00, 0x77, 0x81}) then
      return fail("ammo HUD did not display right-aligned 49")
    end
    teleport(0x1ACD, 0x2A66) -- thing 3, BON1
  elseif frames == 160 then
    if emu.read(0x6A05, MT) ~= 101 or emu.read(0x6A2C, MT) ~= 1 or active(3) then
      return fail("BON1 was not consumed exactly once")
    end
    teleport(0x1800, 0x2CCD) -- thing 1, BON2
  elseif frames == 200 then
    if emu.read(0x6A06, MT) ~= 1 or emu.read(0x6A07, MT) ~= 1 or
       emu.read(0x6A2C, MT) ~= 2 or active(1) then
      return fail("BON2 did not grant armor/type and clear its active bit")
    end
    teleport(0x44CD, 0x2B9A) -- thing 0, ARM2
  elseif frames == 240 then
    if emu.read(0x6A06, MT) ~= 200 or emu.read(0x6A07, MT) ~= 2 or
       emu.read(0x6A2C, MT) ~= 3 or active(0) then
      return fail("ARM2 did not replace armor and clear its active bit")
    end
    teleport(0x3800, 0x2C00) -- thing 9, barrel
  elseif frames == 280 then
    if emu.read(0x6A2C, MT) ~= 3 or not active(9) then
      return fail("barrel was collected")
    end
    if hudBadTiming then return fail("HUD VRAM write occurred outside vblank") end
    if viewRestoreBad then
      return fail(string.format("HUD NMI restore outside vblank: %s (max %d)",
        tostring(viewRestoreBadLine), viewRestoreMax))
    end
    for address in pairs(targets) do
      if not hudRuns[address] then
        return fail(string.format("missing dynamic HUD run at $%04X", address))
      end
    end
    print(string.format("M7 PASS (polls=%d shots=1 ammo=49 pickups=3 health=101 armor=200/type2)", polls))
    emu.stop(0)
  end
end, emu.eventType.endFrame)
