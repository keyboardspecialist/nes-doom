-- M12: swept player-circle collision and close-wall rendering.
local frames = 0
local MT = nil

local function fail(msg)
  print("M12 FAIL: " .. msg)
  emu.stop(1)
end

local function write16(address, value)
  emu.write(address, value % 256, MT)
  emu.write(address + 1, math.floor(value / 256), MT)
end

local function read16(address)
  return emu.read(address, MT) + 256 * emu.read(address + 1, MT)
end

local function foregroundWallVisible()
  local base = emu.read(0x13, MT) == 0 and 0x6000 or 0x6500
  for row = 0, 19 do
    local ex = emu.read(base + 0x280 + 16 * 20 + row, MT)
    if ex % 64 < 12 then return true end
  end
  return false
end

emu.addEventCallback(function()
  local up = (frames > 20 and frames <= 600)
    or (frames > 620 and frames <= 760)
    or (frames > 780 and frames <= 950)
  emu.setInput({up = up}, 0)
end, emu.eventType.inputPolled)

emu.addEventCallback(function()
  frames = frames + 1
  MT = emu.memType.nesDebug

  if frames == 600 then
    local x = read16(0x30)
    if x > 0x1B00 or x < 0x1A80 then
      return fail(string.format("solid-wall clearance x=%04X", x))
    end
    if not foregroundWallVisible() then return fail("wall vanished at collision clearance") end
    -- Centered on the 64-unit portal: this must remain traversable.
    write16(0x30, 0x1900); write16(0x32, 0x0C00); write16(0x34, 0)
  elseif frames == 760 then
    local x = read16(0x30)
    if x <= 0x1C00 then return fail(string.format("centered portal blocked x=%04X", x)) end
    -- Only eight units above the lower jamb; a radius-16 player must not fit.
    write16(0x30, 0x1900); write16(0x32, 0x0A80); write16(0x34, 0)
  elseif frames == 950 then
    local x = read16(0x30)
    if x > 0x1B00 then return fail(string.format("portal jamb clipped x=%04X", x)) end
    -- Defensive renderer case: inside gameplay clearance but outside 4u clip.
    write16(0x30, 0x1B80); write16(0x32, 0x0800); write16(0x34, 0)
  elseif frames == 1080 then
    if not foregroundWallVisible() then return fail("wall vanished at eight-unit depth") end
    print("M12 PASS (solid clearance, portal, jamb, close render)")
    emu.stop(0)
  end
end, emu.eventType.endFrame)
