-- M2: ExAttr proof.
--   Pattern (set by the ROM): view cell (r,c) has ExRAM byte (r%4)<<6 | (c%8)
--   for c<28, bank 0 + NT tiles 0-3 for c=28..31.
--   CHR test banks: bank k tile 0 = solid color 1+(k%3); bank 64+k = 1+((k+1)%3).
--   Rows 0-9 written in mode %10 during blank; rows 10-19 in mode %01 during
--   rendering (by the line-160 IRQ). Both must display identically.
--   At frame 120 the ROM sets $5130=1 -> every bank k now shows CHR bank 64+k.
local frames = 0
local phaseA = nil

local function fail(msg)
  print("M2 FAIL: " .. msg)
  emu.stop(1)
end

local function px(buf, r, c)               -- center pixel of view cell (r,c)
  return buf[(r * 8 + 4) * 256 + (c * 8 + 4) + 1]
end

local function sample()
  local buf = emu.getScreenBuffer()
  local s = { cells = {} }
  for r = 0, 19 do
    s.cells[r] = {}
    for c = 0, 31 do s.cells[r][c] = px(buf, r, c) end
  end
  return s
end

local function checkPattern(s, label)
  local cells = s.cells
  -- bank bits: color index has period 3 in bank -> groups {0,3,6},{1,4,7},{2,5}
  local r = 2
  if cells[r][0] ~= cells[r][3] or cells[r][3] ~= cells[r][6] then
    return fail(label .. ": bank group A mismatch")
  end
  if cells[r][1] ~= cells[r][4] or cells[r][4] ~= cells[r][7] then
    return fail(label .. ": bank group B mismatch")
  end
  if cells[r][2] ~= cells[r][5] then
    return fail(label .. ": bank group C mismatch")
  end
  if cells[r][0] == cells[r][1] or cells[r][1] == cells[r][2]
     or cells[r][0] == cells[r][2] then
    return fail(label .. ": bank groups not distinct (bank bits ignored?)")
  end
  -- palette bits: col 0, rows 0-3 = same tile under palettes 0-3, all distinct
  for a = 0, 3 do
    for b = a + 1, 3 do
      if cells[a][0] == cells[b][0] then
        return fail(label .. string.format(": palettes %d and %d identical", a, b))
      end
    end
  end
  -- ExRAM write-path equivalence: row r (mode %10 at init) vs row r+12
  -- (mode %01 during rendering); (r+12)%4 == r%4 so patterns must match
  for c = 0, 7 do
    if cells[2][c] ~= cells[14][c] then
      return fail(label .. string.format(
        ": col %d differs between blank-written and render-written ExRAM", c))
    end
  end
  -- NT indexing within a bank: cols 28,29,30 = tiles 0,1,2 of bank 0
  if cells[1][28] == cells[1][29] or cells[1][29] == cells[1][30] then
    return fail(label .. ": NT tile variation missing (cols 28-30)")
  end
  print(label .. " OK")
  return true
end

emu.addEventCallback(function()
  frames = frames + 1

  if frames == 60 then
    local s = sample()
    local st = emu.getState()
    if st["mapper.chrUpperBits"] ~= 0 then return fail("phase A: $5130 not 0") end
    if not checkPattern(s, "phase A ($5130=0)") then return end
    phaseA = s
  end

  if frames == 180 then
    local s = sample()
    local st = emu.getState()
    if st["mapper.chrUpperBits"] ~= 1 then return fail("phase B: $5130 not 1") end
    if not checkPattern(s, "phase B ($5130=1)") then return end
    -- $5130 must actually change what's displayed: bank k color shifts one
    -- step, so new cell(2,0) matches old cell(2,1) and differs from old (2,0)
    if s.cells[2][0] == phaseA.cells[2][0] then
      return fail("$5130=1 did not change displayed tiles")
    end
    if s.cells[2][0] ~= phaseA.cells[2][1] then
      return fail("$5130=1 bank shift pattern wrong")
    end
    print("M2 PASS")
    emu.stop(0)
  end
end, emu.eventType.endFrame)
