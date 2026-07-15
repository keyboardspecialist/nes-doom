-- M13: edge-triggered Use, animated E1M1 door, collision, wait, and close.
local frames = 0
local MT = nil

local function fail(msg)
  print("M13 FAIL: " .. msg)
  emu.stop(1)
end

local function write16(address, value)
  emu.write(address, value % 256, MT)
  emu.write(address + 1, math.floor(value / 256), MT)
end

local function read16(address)
  return emu.read(address, MT) + 256 * emu.read(address + 1, MT)
end

emu.addEventCallback(function()
  emu.setInput({
    start = frames < 10,
    b = frames == 110,
    up = frames >= 230 and frames < 460,
  }, 0)
end, emu.eventType.inputPolled)

emu.addEventCallback(function()
  frames = frames + 1
  MT = emu.memType.nesDebug

  if frames == 100 then
    if emu.read(0x7704, MT) ~= 0 then return fail("door ceiling not initialized") end
    -- West side, aiming 45 degrees toward an endpoint rather than the midpoint.
    write16(0x30, 0x3C40)
    write16(0x32, 0x3F33)
    write16(0x34, 0x2000)
  elseif frames == 140 then
    local ceiling = emu.read(0x7704, MT)
    if ceiling == 0 or ceiling >= 27 then
      return fail(string.format("door did not animate after one-poll B tap: %d", ceiling))
    end
    if emu.read(0x7808, MT) ~= 1 then return fail("door not in opening state") end
  elseif frames == 230 then
    if emu.read(0x7704, MT) ~= 27 then return fail("door did not reach open ceiling") end
    if emu.read(0x7808, MT) ~= 2 or emu.read(0x7820, MT) ~= 1 then
      return fail("open door did not publish collision clearance")
    end
    write16(0x34, 0) -- face through the doorway for the passage check
  elseif frames == 460 then
    local x = read16(0x30)
    if x <= 0x3E00 then return fail(string.format(
      "open door remained blocking x=%04X y=%04X joy=%02X/%02X pass=%d",
      x, read16(0x32), emu.read(0x7B, MT), emu.read(0x7C, MT), emu.read(0x80, MT))) end
  elseif frames == 600 then
    local ceiling = emu.read(0x7704, MT)
    if ceiling >= 27 then return fail("door did not start closing after hold") end
    if emu.read(0x7820, MT) ~= 0 then return fail("closing door remained passable") end
  elseif frames == 730 then
    if emu.read(0x7704, MT) ~= 0 or emu.read(0x7808, MT) ~= 0 then
      return fail("door did not finish closing")
    end
    if emu.read(0x8F, MT) ~= 0xC5 then return fail("ZP canary clobbered") end
    print("M13 PASS (Use, animation, passage, wait, close)")
    emu.stop(0)
  end
end, emu.eventType.endFrame)
