-- E1M1: real WAD content through the full pipeline. Structural asserts on
-- the compose buffer at the player start plus a cheap enclosed vantage.
-- Textures: slots in banks 0-59 (4 per texture), flats bank 60
-- (ceiling EX $BC, floor EX $7C).
local frames = 0
local MT = nil

local function fail(msg)
  print("E1M1 FAIL: " .. msg)
  emu.stop(1)
end

local function readCol(col)
  local base = emu.read(0x13, MT) == 0 and 0x6000 or 0x6500
  local nt, ex = {}, {}
  for r = 0, 19 do
    nt[r] = emu.read(base + col * 20 + r, MT)
    ex[r] = emu.read(base + 0x280 + col * 20 + r, MT)
  end
  return nt, ex
end

local function isWall(v)
  return v ~= 0xBC and v ~= 0x7C and v ~= 0 and (v % 64) < 60
end

emu.addEventCallback(function()
  frames = frames + 1
  MT = emu.memType.nesDebug

  if frames == 200 then
    -- player start, facing north up the hangar: ceiling band, textured
    -- walls, floor — real texture banks
    if emu.read(0x8F, MT) ~= 0xC5 then return fail("ZP canary") end
    local pf = emu.read(0x80, MT)
    print(string.format("start view: pass_frames=%d segs=%d cols=%d",
      pf, emu.read(0x82, MT), emu.read(0x81, MT)))
    if pf > 35 then return fail("start view slower than measured envelope") end
    local found = 0
    for _, c in ipairs({ 4, 10, 16, 22, 28 }) do
      local nt, ex = readCol(c)
      local hasCeil, hasWall, hasFloor = false, false, false
      for r = 0, 19 do
        if ex[r] == 0xBC then hasCeil = true end
        if ex[r] == 0x7C then hasFloor = true end
        if isWall(ex[r]) then hasWall = true end
      end
      if hasCeil and hasWall and hasFloor then found = found + 1 end
    end
    if found < 4 then
      return fail("start view lacks ceiling/wall/floor structure (" .. found .. "/5)")
    end
    -- move to an enclosed vantage: near the west wall looking west
    emu.write(0x30, 0x33, MT); emu.write(0x31, 0x1C, MT)
    emu.write(0x35, 0x80, MT); emu.write(0x34, 0x00, MT)
  end

  if frames == 320 then
    local pf = emu.read(0x80, MT)
    print(string.format("near-wall view: pass_frames=%d", pf))
    if pf > 10 then return fail("enclosed view slower than measured envelope") end
    if emu.read(0x8F, MT) ~= 0xC5 then return fail("ZP canary after teleport") end
    local flips = emu.read(0x14, MT) + 256 * emu.read(0x15, MT)
    print(string.format("E1M1 PASS (flips=%d in %d frames)", flips, frames))
    emu.stop(0)
  end
end, emu.eventType.endFrame)
