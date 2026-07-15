-- Full E1M1: untrimmed BSP, banked seg records, and 16-bit vertex endpoints.
local frames = 0
local MT = nil
local done = false

local function fail(msg)
  print("E1M1 FULL FAIL: " .. msg)
  emu.stop(1)
end

local function write16(address, value)
  emu.write(address, value % 256, MT)
  emu.write(address + 1, math.floor(value / 256), MT)
end

emu.addEventCallback(function()
  frames = frames + 1
  MT = emu.memType.nesDebug
  if done then return end

  if frames == 100 then
    -- Barrel 37 is outside the trimmed map and proves the 48-thing payload
    -- was loaded and initialized rather than the 16-thing test subset.
    if emu.read(0x6A2D + 37, MT) ~= 20 then
      return fail("distant full-map things were not initialized")
    end
  elseif frames == 200 then
    local pass = emu.read(0x80, MT)
    local segs = emu.read(0x82, MT)
    local cols = emu.read(0x81, MT)
    if pass > 30 or segs == 0 or cols == 0 then
      return fail(string.format("invalid start render pass=%d segs=%d cols=%d",
        pass, segs, cols))
    end
    if emu.read(0x6AC1, MT) == 0 then
      return fail("16-bit vertex path was not exercised")
    end
    -- Teleport to the distant southern area omitted by the trimmed build.
    write16(0x30, 0x60CD)
    write16(0x32, 0x04CD)
    write16(0x34, 0x4000)
  elseif frames >= 350 then
    local segs = emu.read(0x82, MT)
    local cols = emu.read(0x81, MT)
    if emu.read(0x8F, MT) ~= 0xC5 then return fail("ZP canary in distant area") end
    if segs > 0 and cols > 0 then
      if emu.read(0x6AC0, MT) == 0 then
        return fail("second seg bank was not exercised")
      end
      print(string.format(
        "E1M1 FULL PASS (start+south, pass=%d segs=%d cols=%d, banked vertices/segs)",
        emu.read(0x80, MT), segs, cols))
      done = true
      emu.stop(0)
    end
    if frames > 500 then return fail("timed out") end
  end
end, emu.eventType.endFrame)
