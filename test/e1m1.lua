-- E1M1: real WAD content through the full pipeline. Structural asserts on
-- the compose buffer at the player start plus a cheap enclosed vantage.
-- Textures: variable-packed slots in banks 0-59, flats bank 60
-- (ceiling EX $BC, floor EX $3C/$7C by light level).
local frames = 0
local MT = nil
local secPalBase = nil
local variantSeen = 0

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
  return v ~= 0xFC and v ~= 0xBC and v ~= 0x7C and v ~= 0x3C and v ~= 0 and (v % 64) < 60
end

local function composeHash(base)
  local a, b = 0, 0
  for i = 0, 1279 do
    local v = emu.read(base + i, MT)
    a = (a + v) % 65536
    b = (b + v * (i + 1)) % 65536
  end
  return a, b
end

emu.addEventCallback(function()
  if frames > 320 and frames <= 650 then
    emu.setInput({up = true}, 0)
  end
end, emu.eventType.inputPolled)

emu.addEventCallback(function()
  frames = frames + 1
  MT = emu.memType.nesDebug

  local actualPal = emu.read(0x64, MT) + 256 * emu.read(0x65, MT)
  if not secPalBase and actualPal ~= 0 then
    secPalBase = actualPal - emu.read(0x66, MT) * 16
  end
  local expectedPal = secPalBase and secPalBase + emu.read(0x66, MT) * 16
  if expectedPal and actualPal ~= expectedPal then
    return fail(string.format("palette pointer %04X != displayed sector %d (%04X, base %04X)",
      actualPal, emu.read(0x66, MT), expectedPal, secPalBase))
  end

  if frames > 320 then
    local base = emu.read(0x13, MT) == 0 and 0x6000 or 0x6500
    for i = 0, 639 do
      local bank = emu.read(base + 0x280 + i, MT) % 64
      if bank >= 43 and bank <= 59 then variantSeen = variantSeen + 1 end
    end
  end

  if frames == 200 then
    -- player start, facing north up the hangar: ceiling band, textured
    -- walls, floor — real texture banks
    if emu.read(0x8F, MT) ~= 0xC5 then return fail("ZP canary") end
    local pf = emu.read(0x80, MT)
    print(string.format("start view: pass_frames=%d segs=%d cols=%d sides=%d",
      pf, emu.read(0x82, MT), emu.read(0x81, MT), emu.read(0x83, MT)))
    if pf > 19 then return fail("start view slower than measured envelope") end
    local base = emu.read(0x13, MT) == 0 and 0x6000 or 0x6500
    local ha, hb = composeHash(base)
    if ha ~= 0xDF01 or hb ~= 0x3DF8 then
      return fail(string.format("start compose hash %04X:%04X", ha, hb))
    end
    local found = 0
    for _, c in ipairs({ 4, 10, 16, 22, 28 }) do
      local nt, ex = readCol(c)
      local hasCeil, hasWall, hasFloor = false, false, false
      for r = 0, 19 do
        if nt[r] == 4 and ex[r] == 0xBC then hasCeil = true end
        if nt[r] == 2 and (ex[r] == 0xFC or ex[r] == 0xBC) then hasFloor = true end
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
    -- Return to the start and walk forward through the class-10/11 distance
    -- bands; these are the selectively baked 4-pixel vertical phase variants.
    emu.write(0x30, 0x9A, MT); emu.write(0x31, 0x31, MT)
    emu.write(0x32, 0x33, MT); emu.write(0x33, 0x23, MT)
    emu.write(0x34, 0x00, MT); emu.write(0x35, 0x40, MT)
  end

  if frames == 700 then
    if variantSeen == 0 then return fail("half-row texture variants were never displayed") end
    local flips = emu.read(0x14, MT) + 256 * emu.read(0x15, MT)
    print(string.format("E1M1 PASS (flips=%d in %d frames, half-row cells=%d)",
      flips, frames, variantSeen))
    emu.stop(0)
  end
end, emu.eventType.endFrame)
