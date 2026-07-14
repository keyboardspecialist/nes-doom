-- M6: static pistol sprite overlay, bank mapping, OAM, and viewport clipping.
local frames = 0
local dmaCount, dmaBad = 0, false
local chr = {}
local masks = { view = 0, status = 0, blank = 0,
                statusBlank = 0, letterboxBlank = 0,
                viewMin = 999, viewMax = -1,
                statusMin = 999, statusMax = -1,
                blankMin = 999, blankMax = -1 }
local spriteFrame = nil
local changedPixels = nil

local function fail(msg)
  print("M6 FAIL: " .. msg)
  emu.stop(1)
end

pcall(function()
  emu.addMemoryCallback(function(addr, value)
    dmaCount = dmaCount + 1
    if value ~= 0x02 then dmaBad = true end
  end, emu.callbackType.write, 0x4014)
  emu.addMemoryCallback(function(addr, value)
    chr[addr - 0x5124 + 1] = value
  end, emu.callbackType.write, 0x5124, 0x5127)
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
  frames = frames + 1
  if frames == 220 then
    spriteFrame = emu.getScreenBuffer()
    emu.write(0x03, 0x0E, emu.memType.nesDebug)
  elseif frames == 221 then
    local noSpriteFrame = emu.getScreenBuffer()
    local changed = 0
    for y = 96, 159 do
      for x = 104, 151 do
        local i = y * 256 + x + 1
        if spriteFrame[i] ~= noSpriteFrame[i] then
          changed = changed + 1
        end
      end
    end
    changedPixels = changed
    emu.write(0x03, 0x1E, emu.memType.nesDebug)
  end
  if frames < 280 then return end
  local mt = emu.memType.nesDebug
  if emu.read(0x03, mt) ~= 0x1E then return fail("view PPUMASK shadow is not $1E") end
  if dmaBad or dmaCount < frames - 6 or dmaCount > frames + 2 then
    return fail(string.format("expected one page-$02 DMA/frame, got %d/%d", dmaCount, frames))
  end
  for i, value in ipairs({0xFC, 0xFD, 0xFE, 0xFF}) do
    if chr[i] ~= value then
      return fail(string.format("CHR sprite page %d is %s", i, tostring(chr[i])))
    end
  end
  if masks.view < 100 or masks.status < 100 or masks.blank < 100 then
    return fail(string.format("PPUMASK phases missing: view=%d status=%d blank=%d",
      masks.view, masks.status, masks.blank))
  end
  if masks.viewMin < 241 or masks.viewMax > 258 then
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

  local active = 0
  local scanlines = {}
  for i = 0, 63 do
    local base = 0x0200 + i * 4
    local y = emu.read(base, mt)
    if i < 36 then
      local tile = emu.read(base + 1, mt)
      local attr = emu.read(base + 2, mt)
      local x = emu.read(base + 3, mt)
      if y == 0xFF or tile >= 64 or attr ~= 0 then return fail("invalid active OAM record") end
      if x < 104 or x > 144 or y + 8 > 159 then return fail("weapon outside viewport") end
      active = active + 1
      for line = y + 1, y + 8 do scanlines[line] = (scanlines[line] or 0) + 1 end
    elseif y ~= 0xFF then
      return fail("unused OAM sprite is visible")
    end
  end
  local peak = 0
  for _, count in pairs(scanlines) do if count > peak then peak = count end end
  if active ~= 36 or peak ~= 6 then
    return fail(string.format("OAM budget active=%d peak=%d", active, peak))
  end
  if changedPixels ~= 1244 then
    return fail("weapon pixel signature changed: " .. tostring(changedPixels))
  end
  print(string.format("M6 PASS (sprites=%d, peak/scanline=%d, pixels=%d, DMA=%d)",
    active, peak, changedPixels, dmaCount))
  emu.stop(0)
end, emu.eventType.endFrame)
