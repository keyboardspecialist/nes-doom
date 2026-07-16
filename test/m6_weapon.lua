-- M6: MMC5-independent 8x16 weapon/world sprites, OAM, and clipping.
local frames = 0
local dmaCount, dmaBad = 0, false
local chr = {}
local chrHiOne, chrHiZero = false, false
local hudWindowAtSplit, gameplayWindowAtVblank = false, false
local masks = { view = 0, status = 0, blank = 0,
                statusBlank = 0, letterboxBlank = 0,
                viewMin = 999, viewMax = -1,
                statusMin = 999, statusMax = -1,
                blankMin = 999, blankMax = -1 }
local spriteFrame = nil
local changedPixels = nil
local weaponBankSeen = {}

local function fail(msg)
  print("M6 FAIL: " .. msg)
  emu.stop(1)
end

pcall(function()
  emu.addMemoryCallback(function(addr, value)
    dmaCount = dmaCount + 1
    local mt = emu.memType.nesDebug
    local expected = emu.read(0x0F, mt) + emu.read(0x6A29, mt)
    if value ~= expected then dmaBad = true end
  end, emu.callbackType.write, 0x4014)
  emu.addMemoryCallback(function(addr, value)
    chr[addr - 0x5120 + 1] = value
    if addr >= 0x5126 then weaponBankSeen[value] = true end
  end, emu.callbackType.write, 0x5120, 0x5127)
  emu.addMemoryCallback(function(addr, value)
    local line = emu.getState()["ppu.scanline"]
    if value == 1 then chrHiOne = true end
    if chrHiOne and value == 0 then chrHiZero = true end
    if value == 1 and line >= 159 and line <= 163 then hudWindowAtSplit = true end
    if value == 0 and line >= 241 then gameplayWindowAtVblank = true end
  end, emu.callbackType.write, 0x5130)
  emu.addMemoryCallback(function(addr, value)
    if frames <= 10 or (frames >= 219 and frames <= 222) then return end
    local line = emu.getState()["ppu.scanline"]
    if value == 0x1E then
      masks.view = masks.view + 1
      if line < masks.viewMin then masks.viewMin = line end
      if line > masks.viewMax then masks.viewMax = line end
    elseif value == 0x0E then
      masks.status = masks.status + 1
      if line < masks.statusMin then masks.statusMin = line end
      if line > masks.statusMax then masks.statusMax = line end
    elseif value == 0x00 then
      masks.blank = masks.blank + 1
      if line >= 159 and line <= 163 then masks.statusBlank = masks.statusBlank + 1 end
      if line >= 198 and line <= 200 then masks.letterboxBlank = masks.letterboxBlank + 1 end
      if line < masks.blankMin then masks.blankMin = line end
      if line > masks.blankMax then masks.blankMax = line end
    end
  end, emu.callbackType.write, 0x2001)
end)

emu.addEventCallback(function()
  emu.setInput({start = frames < 10, a = frames >= 120 and frames < 123}, 0)
end, emu.eventType.inputPolled)

emu.addEventCallback(function()
  frames = frames + 1
  if frames == 220 then
    spriteFrame = emu.getScreenBuffer()
    emu.write(0x03, 0x0E, emu.memType.nesDebug)
  elseif frames == 221 then
    local noSpriteFrame = emu.getScreenBuffer()
    local changed = 0
    for y = 112, 159 do
      for x = 96, 151 do
        local i = y * 256 + x + 1
        if spriteFrame[i] ~= noSpriteFrame[i] then
          changed = changed + 1
        end
      end
    end
    changedPixels = changed
    emu.write(0x03, 0x1E, emu.memType.nesDebug)
  elseif frames == 230 then
    -- Stand just south of a retained barrel and look north.
    local mt = emu.memType.nesDebug
    emu.write(0x30, 0x00, mt); emu.write(0x31, 0x38, mt)
    emu.write(0x32, 0x80, mt); emu.write(0x33, 0x2A, mt)
    emu.write(0x34, 0x00, mt); emu.write(0x35, 0x40, mt)
  end
  if frames < 280 then return end
  local mt = emu.memType.nesDebug
  if emu.read(0x03, mt) ~= 0x1E then return fail("view PPUMASK shadow is not $1E") end
  -- TITLEPIC holds the first few frames without gameplay OAM DMA.
  if dmaBad or dmaCount < frames - 12 or dmaCount > frames + 2 then
    return fail(string.format("expected one published-set weapon DMA/frame, got %d/%d", dmaCount, frames))
  end
  for i, value in ipairs({0, 1, 2, 3, 4, 5, 6, 7}) do
    if chr[i] ~= value then
      return fail(string.format("CHR sprite page %d is %s", i, tostring(chr[i])))
    end
  end
  if not chrHiOne or not chrHiZero then return fail("sprite CHR high bits were not latched") end
  if not hudWindowAtSplit or not gameplayWindowAtVblank then
    return fail("HUD/gameplay CHR windows were not split and restored")
  end
  for _, value in ipairs({6, 7, 8, 9, 10, 11, 12, 13}) do
    if not weaponBankSeen[value] then
      return fail(string.format("weapon CHR page %d was never selected", value))
    end
  end
  if emu.read(0x02, mt) ~= 0xA8 then return fail("PPUCTRL is not in 8x16 mode") end
  if masks.view < 100 or masks.status < 100 or masks.blank < 100 then
    return fail(string.format("PPUMASK phases missing: view=%d status=%d blank=%d",
      masks.view, masks.status, masks.blank))
  end
  if masks.viewMin < 241 or masks.viewMax > 260 then
    return fail(string.format("view restore outside vblank: %d-%d",
      masks.viewMin, masks.viewMax))
  end
  if masks.statusMin < 160 or masks.statusMax > 163 then
    return fail(string.format("status split mistimed: %d-%d",
      masks.statusMin, masks.statusMax))
  end
  if masks.blankMin < 159 or masks.blankMax > 200 then
    return fail(string.format("blank phase mistimed: %d-%d",
      masks.blankMin, masks.blankMax))
  end
  if masks.statusBlank < 100 or masks.letterboxBlank < 100 then
    return fail(string.format("missing blank cluster: status=%d letterbox=%d",
      masks.statusBlank, masks.letterboxBlank))
  end

  if emu.read(0x6A29, mt) ~= 0 then return fail("final weapon frame is not idle") end
  local set = emu.read(0x0F, mt)
  local page = (set + emu.read(0x6A29, mt)) * 256
  local back = 1 - emu.read(0x13, mt)
  if emu.read(0x6A02 + back, mt) == set then
    return fail("renderer back OAM set aliases the DMA set")
  end
  local active, weapon, world, barrelCells = 0, 0, 0, 0
  local scanlines = {}
  for i = 0, 63 do
    local base = page + i * 4
    local y = emu.read(base, mt)
    if y ~= 0xFF then
      local tile = emu.read(base + 1, mt)
      local attr = emu.read(base + 2, mt)
      local x = emu.read(base + 3, mt)
      if y + 16 > 159 then return fail("sprite outside viewport") end
      if i < 20 then
        if attr ~= 0 or x < 96 or x > 144 or y + 1 < 112 then
          return fail("invalid weapon OAM record")
        end
        weapon = weapon + 1
      else
        if attr > 3 then return fail("invalid world sprite palette") end
        if attr == 0 then barrelCells = barrelCells + 1 end
        world = world + 1
      end
      active = active + 1
      for line = y + 1, y + 16 do scanlines[line] = (scanlines[line] or 0) + 1 end
    end
  end
  local peak = 0
  for _, count in pairs(scanlines) do if count > peak then peak = count end end
  for i = 20, 62 do
    for byte = 0, 3 do
      local expected = emu.read(set * 256 + i * 4 + byte, mt)
      for frame = 1, 3 do
        if emu.read((set + frame) * 256 + i * 4 + byte, mt) ~= expected then
          return fail("world OAM differs between weapon-frame pages")
        end
      end
    end
  end
  if weapon ~= 17 or world == 0 or barrelCells == 0 or peak > 8 then
    return fail(string.format("OAM budget weapon=%d world=%d barrelCells=%d peak=%d",
      weapon, world, barrelCells, peak))
  end
  if changedPixels ~= 784 then
    return fail("weapon pixel signature changed: " .. tostring(changedPixels))
  end
  print(string.format("M6 PASS (weapon=%d, world=%d, barrelCells=%d, peak/scanline=%d, pixels=%d, DMA=%d)",
    weapon, world, barrelCells, peak, changedPixels, dmaCount))
  emu.stop(0)
end, emu.eventType.endFrame)
