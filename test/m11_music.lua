-- M11: compiled D_E1M1 drives all five tonal voices plus noise/DPCM drums.
local frames = 0
local MT = nil
local writes = {p0 = 0, p1 = 0, tri = 0, m0 = 0, m1 = 0, noise = 0}
local periods = {p0 = {}, p1 = {}, tri = {}, m0 = {}, m1 = {}}
local musicBanks, dpcmStarts, pistolSounds = 0, 0, 0
local mmc5Enabled, dmcIrqEnabled = false, false
local voicesChecked = false
local stressFrames, stressChecks = 0, 0
local stressArmed = false
local noiseLengthHalted = false

local function fail(msg)
  print("M11 FAIL: " .. msg)
  emu.stop(1)
end

local function distinct(values)
  local count = 0
  for _ in pairs(values) do count = count + 1 end
  return count
end

pcall(function()
  emu.addMemoryCallback(function(_addr, value)
    musicBanks = musicBanks + (value == 0x88 and 1 or 0)
  end, emu.callbackType.write, 0x5114)
  emu.addMemoryCallback(function(_addr, value)
    if value == 3 then mmc5Enabled = true end
  end, emu.callbackType.write, 0x5015)
  emu.addMemoryCallback(function(_addr, value)
    if value >= 0x80 then dmcIrqEnabled = true end
  end, emu.callbackType.write, 0x4010)
  emu.addMemoryCallback(function(_addr, value)
    if value == 0x1F then
      dpcmStarts = dpcmStarts + 1
      if frames > 100 and not stressArmed then
        stressFrames = 5
        stressArmed = true
      end
    end
  end, emu.callbackType.write, 0x4015)
  emu.addMemoryCallback(function(_addr, value)
    writes.p0 = writes.p0 + 1; periods.p0[value] = true
  end, emu.callbackType.write, 0x4002)
  emu.addMemoryCallback(function(_addr, value)
    writes.p1 = writes.p1 + 1; periods.p1[value] = true
  end, emu.callbackType.write, 0x4006)
  emu.addMemoryCallback(function(_addr, value)
    writes.tri = writes.tri + 1; periods.tri[value] = true
  end, emu.callbackType.write, 0x400A)
  emu.addMemoryCallback(function(_addr, value)
    writes.m0 = writes.m0 + 1; periods.m0[value] = true
  end, emu.callbackType.write, 0x5002)
  emu.addMemoryCallback(function(_addr, value)
    writes.m1 = writes.m1 + 1; periods.m1[value] = true
  end, emu.callbackType.write, 0x5006)
  emu.addMemoryCallback(function(_addr, value)
    writes.noise = writes.noise + 1
    if value == 0x18 then pistolSounds = pistolSounds + 1 end
  end, emu.callbackType.write, 0x400F)
  emu.addMemoryCallback(function(_addr, value)
    if frames > 20 and math.floor(value / 0x20) % 2 == 1 then
      noiseLengthHalted = true
    end
  end, emu.callbackType.write, 0x400C)
end)

emu.addEventCallback(function()
  emu.setInput({start = frames < 10, a = frames >= 650 and frames < 653,
                right = stressFrames > 0}, 0)
end, emu.eventType.inputPolled)

emu.addEventCallback(function()
  frames = frames + 1
  MT = emu.memType.nesDebug
  if stressFrames > 0 then
    if stressFrames <= 3 then
      stressChecks = stressChecks + 1
      if emu.read(0x05, MT) ~= 0x80 then
        return fail("DPCM-safe controller poll lost Right")
      end
    end
    stressFrames = stressFrames - 1
  end
  if frames == 800 then
    if not mmc5Enabled then return fail("MMC5 pulse channels were not enabled") end
    if dmcIrqEnabled then return fail("DMC IRQ was enabled") end
    if noiseLengthHalted then return fail("music noise halted its length counter") end
    if musicBanks < 100 then return fail("music bank was not consumed") end
    if emu.read(0x7F03, MT) ~= 0 then
      return fail("music skipped during normal pusher timing")
    end
    if emu.read(0x7F10, MT) < 100 then return fail("too few music records") end
    if emu.read(0x7F11, MT) == 0 or dpcmStarts == 0 then
      return fail("DPCM percussion did not trigger")
    end
    if stressChecks == 0 then return fail("controller was not tested during DPCM") end
    for _, voice in ipairs({"p0", "p1", "tri", "m0", "m1"}) do
      local minimumPeriods = voice == "tri" and 1 or 2
      if writes[voice] == 0 or distinct(periods[voice]) < minimumPeriods then
        return fail(string.format("inactive/static %s writes=%d periods=%d",
          voice, writes[voice], distinct(periods[voice])))
      end
    end
    if writes.noise < 5 then
      return fail("noise percussion did not trigger: " .. writes.noise)
    end
    if pistolSounds ~= 1 then return fail("pistol SFX arbitration changed") end
    if emu.read(0x16, MT) ~= 0x80 then return fail("PRG bank shadow was not restored") end
    voicesChecked = true
  elseif frames == 5900 then
    if not voicesChecked then return fail("initial voice checks did not run") end
    if emu.read(0x7F04, MT) ~= 1 then
      return fail("96-second score did not loop exactly once")
    end
    if emu.read(0x7F03, MT) ~= 0 then return fail("music skipped before loop") end
    print(string.format(
      "M11 PASS (loop=1 banks=%d DPCM=%d tonal=%d/%d/%d/%d/%d noise=%d)",
      musicBanks, dpcmStarts, writes.p0, writes.p1, writes.tri,
      writes.m0, writes.m1, writes.noise))
    emu.stop(0)
  elseif frames > 5940 then
    return fail("timed out")
  end
end, emu.eventType.endFrame)
