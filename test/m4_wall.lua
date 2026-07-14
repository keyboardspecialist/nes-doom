-- M4: single textured sector, rotation + movement.
-- Verifies compose-buffer structure (deterministic) rather than raw pixels:
-- ceiling/wall/floor runs, consecutive slice tiles, then rotation and
-- movement actually change the rendered geometry and camera.
local frames = 0
local before = nil
local maxCols = 0

local function fail(msg)
  print("M4 FAIL: " .. msg)
  emu.stop(1)
end

local MT = nil

local function frontBase()
  local fb = emu.read(0x13, MT)
  return fb == 0 and 0x6000 or 0x6500
end

local function readCol(base, col)
  local nt, ex = {}, {}
  for r = 0, 19 do
    nt[r] = emu.read(base + col * 20 + r, MT)
    ex[r] = emu.read(base + 0x280 + col * 20 + r, MT)
  end
  return nt, ex
end

local function colSignature(col)
  local nt = select(1, readCol(frontBase(), col))
  local s = ""
  for r = 0, 19 do s = s .. string.format("%02X", nt[r]) end
  return s
end

emu.addEventCallback(function()
  if frames > 130 and frames <= 250 then
    emu.setInput({right = true}, 0)     -- rotate
  elseif frames > 280 and frames <= 340 then
    emu.setInput({up = true}, 0)        -- move forward
  end
end, emu.eventType.inputPolled)

emu.addEventCallback(function()
  frames = frames + 1
  MT = emu.memType.nesDebug

  -- cols_drawn resets at each pass start; a pass spans several frames, so
  -- any single sample may be mid-pass. Track the max instead.
  if frames > 30 then
    local c = emu.read(0x81, MT)
    if c > maxCols then maxCols = c end
  end

  if frames == 120 then
    -- static scene: camera at room center looking +X at the east wall
    local canary = emu.read(0x8F, MT)
    local passf = emu.read(0x80, MT)
    local cols = maxCols
    print(string.format("static: pass_frames=%d cols_drawn=%d canary=%02X",
      passf, cols, canary))
    if canary ~= 0xC5 then return fail("ZP canary clobbered") end
    -- flat-room renderer measured 3 frames/pass; BSP renderer 6 at this
    -- vantage — the 8 fps product floor allows 7
    if passf > 7 then return fail("render pass exceeds 7 frames") end
    if cols < 28 then return fail("fewer than 28 columns emitted") end

    local nt, ex = readCol(frontBase(), 16)
    -- row 1: pure ceiling (row 2 may hold a pixel-precision edge tile)
    if ex[1] ~= 0x88 or nt[1] ~= 0x04 then
      return fail(string.format("ceiling wrong at col16 row1: NT=%02X EX=%02X", nt[1], ex[1]))
    end
    if (ex[17] ~= 0x48 and ex[17] ~= 0x08) or nt[17] ~= 0x02 then
      return fail(string.format("floor wrong at col16 row17: NT=%02X EX=%02X", nt[17], ex[17]))
    end
    -- wall run around the center: consecutive slice tiles, texture bank 0-3
    local mid = 9
    if ex[mid] == 0x88 or ex[mid] == 0x48 or ex[mid] == 0x08 then
      return fail("no wall at screen center")
    end
    local bank = ex[mid] % 64
    if bank > 3 then return fail("wall EX bank not a texture bank") end
    if nt[mid + 1] ~= (nt[mid] + 1) % 256 then
      return fail("wall slice tiles not consecutive")
    end
    before = { sig = colSignature(16),
               pang = emu.read(0x34, MT) + 256 * emu.read(0x35, MT) }
    if before.pang ~= 0 then return fail("camera rotated before input") end
  end

  if frames == 270 then
    local pang = emu.read(0x34, MT) + 256 * emu.read(0x35, MT)
    print(string.format("after rotate: pang=%04X", pang))
    if pang == 0 then return fail("rotation input had no effect") end
    if colSignature(16) == before.sig then
      return fail("view unchanged after rotating") end
  end

  if frames == 360 then
    local px = emu.read(0x30, MT) + 256 * emu.read(0x31, MT)
    local py = emu.read(0x32, MT) + 256 * emu.read(0x33, MT)
    print(string.format("after move: px=%04X py=%04X", px, py))
    if px == 0x1000 and py == 0x0C00 then
      return fail("movement input had no effect")
    end
    local canary = emu.read(0x8F, MT)
    if canary ~= 0xC5 then return fail("ZP canary clobbered after motion") end
    local flips = emu.read(0x14, MT) + 256 * emu.read(0x15, MT)
    print(string.format("M4 PASS (flips=%d in %d frames, %.2f frames/flip)",
      flips, frames, frames / math.max(flips, 1)))
    emu.stop(0)
  end
end, emu.eventType.endFrame)
