-- M5: micro-map BSP — occlusion, portals (upper/lower walls), variable
-- heights, per-sector light. Four scripted vantages via debug writes to the
-- camera; assertions read the front compose buffer (deterministic).
--
-- Map: room A (ceil 128) + pillar, corridor (ceil 96, light 2),
-- room B (floor 16, light 1). Textures: 0=brick (CHR banks 0-3),
-- 1=stone (banks 4-7). FLAT_BANK=8: ceiling EX $88, floor EX $48.
local frames = 0
local vantage = 0
local worstPass = 0

local function fail(msg)
  print("M5 FAIL: " .. msg)
  emu.stop(1)
end

local MT = nil

local function readCol(col)
  local base = emu.read(0x13, MT) == 0 and 0x6000 or 0x6500
  local nt, ex = {}, {}
  for r = 0, 19 do
    nt[r] = emu.read(base + col * 20 + r, MT)
    ex[r] = emu.read(base + 0x280 + col * 20 + r, MT)
  end
  return nt, ex
end

local function isTex(v, lo, hi)
  if v == 0x88 or v == 0x48 then return false end
  local bank = v % 64
  return bank >= lo and bank <= hi
end

local function teleport(x, y, ang)
  emu.write(0x30, (x * 16) % 256, MT)
  emu.write(0x31, math.floor(x * 16 / 256), MT)
  emu.write(0x32, (y * 16) % 256, MT)
  emu.write(0x33, math.floor(y * 16 / 256), MT)
  emu.write(0x34, ang % 256, MT)
  emu.write(0x35, math.floor(ang / 256), MT)
end

local function checkPass()
  local p = emu.read(0x80, MT)
  if p > worstPass then worstPass = p end
  if p > 7 then return fail("render pass " .. p .. " frames (> 7, fps < 8)") end
  if emu.read(0x8F, MT) ~= 0xC5 then return fail("ZP canary clobbered") end
  return true
end

emu.addEventCallback(function()
  frames = frames + 1
  MT = emu.memType.nesDebug

  if frames == 120 then
    -- V1: room A center (256,128) looking +X: solid east wall at center,
    -- portal composite left-of-center, tall south wall right
    if not checkPass() then return end
    local nt, ex = readCol(16)
    if not isTex(ex[9], 0, 3) then
      return fail(string.format("V1: no tex0 wall at col16 row9 (EX=%02X)", ex[9]))
    end
    if nt[10] ~= (nt[9] + 1) % 256 then return fail("V1: slice tiles not consecutive") end
    local _, ex10 = readCol(10)
    local upper, corr = false, false
    for r = 0, 19 do
      if isTex(ex10[r], 0, 3) then upper = true end
      if isTex(ex10[r], 4, 7) then corr = true end
    end
    if not upper then return fail("V1: portal upper wall (tex0) missing at col10") end
    if not corr then return fail("V1: corridor wall (tex1) missing through portal at col10") end
    local _, ex24 = readCol(24)
    local walls = 0
    for r = 0, 19 do if isTex(ex24[r], 0, 7) then walls = walls + 1 end end
    if walls < 12 then return fail("V1: near south wall not tall at col24") end
    print("V1 OK (pass_frames=" .. emu.read(0x80, MT) .. ")")
    teleport(128, 192, 0)   -- V2: pillar dead ahead (occlusion)
    vantage = 2
  end

  if frames == 240 and vantage == 2 then
    if not checkPass() then return end
    local nt, ex = readCol(16)
    if not isTex(ex[9], 4, 7) then
      return fail(string.format("V2: pillar (tex1) not at col16 (EX=%02X)", ex[9]))
    end
    local walls = 0
    for r = 0, 19 do if isTex(ex[r], 4, 7) then walls = walls + 1 end end
    if walls < 12 then return fail("V2: pillar face not tall enough") end
    print("V2 OK (pass_frames=" .. emu.read(0x80, MT) .. ")")
    teleport(384, 192, 0)   -- V3: down the corridor into room B
    vantage = 3
  end

  if frames == 360 and vantage == 3 then
    if not checkPass() then return end
    local nt, ex = readCol(16)
    -- expect: far room-B wall (tex0, light 3) with the step-up lower wall
    -- (tex1) below it, then floor
    local farRow, stepRow = nil, nil
    for r = 0, 19 do
      if farRow == nil and isTex(ex[r], 0, 3) then farRow = r end
      if farRow and stepRow == nil and isTex(ex[r], 4, 7) then stepRow = r end
    end
    if not farRow then return fail("V3: far room-B wall missing at col16") end
    if not stepRow then return fail("V3: step lower wall (tex1) missing below far wall") end
    if stepRow <= farRow then return fail("V3: step not below far wall") end
    print(string.format("V3 OK (far wall row %d, step row %d, pass_frames=%d)",
      farRow, stepRow, emu.read(0x80, MT)))
    teleport(700, 192, 0x8000)  -- V4: from deep in room B looking back west
                                -- (far enough that the portal lintel is on-screen)
    vantage = 4
  end

  if frames == 480 and vantage == 4 then
    if not checkPass() then return end
    local nt, ex = readCol(16)
    -- expect: B-portal upper wall (tex0) above corridor content (tex1)
    local upperRow, corrRow = nil, nil
    for r = 0, 19 do
      if upperRow == nil and isTex(ex[r], 0, 3) then upperRow = r end
      if upperRow and corrRow == nil and isTex(ex[r], 4, 7) then corrRow = r end
    end
    if not upperRow then return fail("V4: B-portal upper wall missing") end
    if not corrRow then return fail("V4: corridor beyond portal missing") end
    print(string.format("V4 OK (upper row %d, corridor row %d, pass_frames=%d)",
      upperRow, corrRow, emu.read(0x80, MT)))
    local flips = emu.read(0x14, MT) + 256 * emu.read(0x15, MT)
    print(string.format("M5 PASS (worst pass_frames=%d, flips=%d in %d frames)",
      worstPass, flips, frames))
    emu.stop(0)
  end
end, emu.eventType.endFrame)
