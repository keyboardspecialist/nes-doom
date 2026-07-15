-- M8: pistol hitscan, destructible barrels, BEXP lifetime, and noise voice.
local frames = 0
local MT = nil
local state = "boot"
local stateAt = 0
local wantFire = false
local shotBefore, ammoBefore, hitsBefore = 0, 0, 0
local pistolSounds, explosionSounds = 0, 0
local liveSignature, liveScreen = nil, nil
local explosionOam, explosionVisual = false, false
local explosionPixels = 0
local retainedAtTen = false
local deathAt = nil

local SHOT_COUNT = 0x6A2B
local THING_HEALTH = 0x6A2D
local THING_DEATH_AT = 0x6A6D
local SHOT_SEEN = 0x6AAD
local SHOT_PENDING = 0x6AAE
local HIT_COUNT = 0x6AB2
local BARREL_KILLS = 0x6AB3
local EXPLOSION_RENDER_COUNT = 0x6AB7
local EXPLOSION_OAM_COUNT = 0x6AFE

local function fail(msg)
  print("M8 FAIL: " .. msg)
  emu.stop(1)
end

local function active(index)
  local value = emu.read(0x6A08 + math.floor(index / 8), MT)
  return math.floor(value / (2 ^ (index % 8))) % 2 == 1
end

local function write16(address, value)
  emu.write(address, value % 256, MT)
  emu.write(address + 1, math.floor(value / 256), MT)
end

local function setCamera(x, y, angle)
  write16(0x30, x)
  write16(0x32, y)
  write16(0x34, angle)
end

local function startFire(nextState)
  shotBefore = emu.read(SHOT_COUNT, MT)
  ammoBefore = emu.read(0x6A04, MT)
  hitsBefore = emu.read(HIT_COUNT, MT)
  wantFire = true
  state = nextState
  stateAt = frames
end

local function shotArrived()
  if emu.read(SHOT_COUNT, MT) == shotBefore then return false end
  wantFire = false
  return true
end

local function shotResolved()
  local count = emu.read(SHOT_COUNT, MT)
  return emu.read(SHOT_PENDING, MT) == 0 and
         emu.read(SHOT_SEEN, MT) == count
end

local function centeredBarrelSignature()
  local page = (emu.read(0x0F, MT) + emu.read(0x6A29, MT)) * 256
  local cells = {}
  for slot = 20, 62 do
    local base = page + slot * 4
    local y = emu.read(base, MT)
    local attr = emu.read(base + 2, MT)
    local x = emu.read(base + 3, MT)
    if y ~= 0xFF and attr == 0 and x >= 80 and x <= 176 and y < 144 then
      table.insert(cells, string.format("%02X:%02X:%02X",
        emu.read(base + 1, MT), y, x))
    end
  end
  return table.concat(cells, ",")
end

local function viewChanged(before, after)
  if not before or not after then return 0 end
  local changed = 0
  -- The nearby barrel can project into the bottom of the 160-line viewport.
  for y = 16, 159 do
    for x = 80, 176 do
      local index = y * 256 + x + 1
      if before[index] ~= after[index] then changed = changed + 1 end
    end
  end
  return changed
end

emu.addEventCallback(function()
  emu.setInput({a = wantFire}, 0)
end, emu.eventType.inputPolled)

pcall(function()
  emu.addMemoryCallback(function(addr, value)
    if frames < 50 then return end
    if value == 0x18 then pistolSounds = pistolSounds + 1 end
    if value == 0x30 then explosionSounds = explosionSounds + 1 end
  end, emu.callbackType.write, 0x400F)
end)

emu.addEventCallback(function()
  frames = frames + 1
  MT = emu.memType.nesDebug

  if frames > 700 then return fail("combat test timed out in " .. state) end

  if state == "boot" and frames == 80 then
    if emu.read(THING_HEALTH + 9, MT) ~= 20 or
       emu.read(THING_HEALTH + 10, MT) ~= 20 or
       emu.read(THING_HEALTH + 13, MT) ~= 20 then
      return fail("generated barrel health was not initialized to 20")
    end
    -- Stand south of thing 9, far enough that BEXP remains above the
    -- weapon-saturated scanlines, and look north through a clear center clip.
    setCamera(0x3800, 0x2800, 0x4000)
    state = "settle_clear"
    stateAt = frames

  elseif state == "settle_clear" and frames - stateAt >= 55 then
    liveSignature = centeredBarrelSignature()
    liveScreen = emu.getScreenBuffer()
    if liveSignature == "" then return fail("live barrel produced no centered OAM") end
    startFire("nonlethal_fire")

  elseif state == "nonlethal_fire" and shotArrived() then
    state = "nonlethal_resolve"
    stateAt = frames

  elseif state == "nonlethal_resolve" and shotResolved() then
    local health = emu.read(THING_HEALTH + 9, MT)
    local damage = 20 - health
    if emu.read(HIT_COUNT, MT) ~= hitsBefore + 1 or
       (damage ~= 5 and damage ~= 10 and damage ~= 15) or health == 0 then
      return fail(string.format("invalid nonlethal hit: health=%d hits=%d",
        health, emu.read(HIT_COUNT, MT)))
    end
    if emu.read(THING_HEALTH + 10, MT) ~= 20 then
      return fail("non-targeted barrel health changed")
    end
    state = "wait_kill_ready"
    stateAt = frames

  elseif state == "wait_kill_ready" and
         emu.read(0x6A29, MT) == 0 and emu.read(0x6A2A, MT) == 0 and
         frames - stateAt >= 2 then
    -- Keep the first hit genuinely nonlethal, then make the lethal roll finite
    -- and independent of which canonical 5/10/15 value comes next.
    emu.write(THING_HEALTH + 9, 5, MT)
    startFire("kill_fire")

  elseif state == "kill_fire" then
    if shotArrived() then stateAt = frames end
    if emu.read(THING_HEALTH + 9, MT) == 0 then
      wantFire = false
      deathAt = emu.read(THING_DEATH_AT + 9, MT)
      if not active(9) then return fail("lethal hit cleared active bit immediately") end
      if emu.read(HIT_COUNT, MT) ~= hitsBefore + 1 or
         emu.read(BARREL_KILLS, MT) ~= 1 then
        return fail("lethal hit counters are incorrect")
      end
      state = "exploding"
      stateAt = frames
    end

  elseif state == "exploding" then
    local age = (emu.read(0x50, MT) - deathAt) % 256
    if emu.read(EXPLOSION_OAM_COUNT, MT) > 0 then explosionOam = true end
    local changed = viewChanged(liveScreen, emu.getScreenBuffer())
    if changed > explosionPixels then explosionPixels = changed end
    if changed > 20 then explosionVisual = true end
    if age >= 10 and age < 60 and active(9) then retainedAtTen = true end
    if not active(9) then
      if age < 60 then return fail("barrel active bit cleared before age 60") end
      if emu.read(THING_HEALTH + 9, MT) ~= 0 then
        return fail("removed barrel regained health")
      end
      if not retainedAtTen then return fail("active bit was not retained during BEXP") end
      if not explosionOam or not explosionVisual then
        return fail(string.format("BEXP missing from output (oam=%s pixels=%d)",
          tostring(explosionOam), explosionPixels))
      end
      if emu.read(EXPLOSION_RENDER_COUNT, MT) == 0 then
        return fail("BEXP metadata path was never rendered")
      end
      if explosionSounds ~= 1 then
        return fail("explosion noise reports=" .. tostring(explosionSounds))
      end
      if pistolSounds ~= 2 or emu.read(0x6A04, MT) ~= 48 then
        return fail(string.format("pistol reports/ammo mismatch: sounds=%d ammo=%d",
          pistolSounds, emu.read(0x6A04, MT)))
      end
      if emu.read(HIT_COUNT, MT) ~= 2 or emu.read(BARREL_KILLS, MT) ~= 1 or
         emu.read(THING_HEALTH + 10, MT) ~= 20 then
        return fail("final combat counters or non-target health changed")
      end
      print(string.format(
        "M8 PASS (shots=2 hits=2 kills=1 other=20 BEXP age=%d sounds=2+1)", age))
      state = "done"
      emu.stop(0)
    end
  end
end, emu.eventType.endFrame)
