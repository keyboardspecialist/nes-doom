-- M9: real E1M1 zombiemen pursue, attack, take pistol damage, die, and expire.
local frames = 0
local MT = nil
local state = "boot"
local stateAt = 0
local wantFire = false
local enemySounds = 0
local startX = nil
local deathAt = nil
local deathX, deathY = nil, nil

local THING_HEALTH = 0x6A2D
local THING_DEATH_AT = 0x6A6D
local WEAPON_FRAME = 0x6A29
local WEAPON_TIMER = 0x6A2A
local MONSTER_X_LO = 0x6AC2
local MONSTER_X_HI = 0x6ACA
local MONSTER_Y_LO = 0x6AD2
local MONSTER_Y_HI = 0x6ADA
local MONSTER_LAST_ATTACK = 0x6AF2
local ZOMBIE_KILLS = 0x6AFB
local ENEMY_ATTACKS = 0x6AFC
local ENEMY_HITS = 0x6AFD
local TARGET = 26
local OTHER = 18
local SLOT = 2

local function fail(msg)
  print("M9 FAIL: " .. msg)
  emu.stop(1)
end

local function read16(address)
  return emu.read(address, MT) + 256 * emu.read(address + 8, MT)
end

local function write16(address, value)
  emu.write(address, value % 256, MT)
  emu.write(address + 1, math.floor(value / 256), MT)
end

local function active(index)
  local value = emu.read(0x6A08 + math.floor(index / 8), MT)
  return math.floor(value / (2 ^ (index % 8))) % 2 == 1
end

local function enemyOamRows()
  local page = (emu.read(0x0F, MT) + emu.read(WEAPON_FRAME, MT)) * 256
  local rows = {}
  for slot = 20, 62 do
    local base = page + slot * 4
    local y = emu.read(base, MT)
    local attr = emu.read(base + 2, MT)
    if y ~= 0xFF and attr == 0 then rows[y] = true end
  end
  local count = 0
  for _ in pairs(rows) do count = count + 1 end
  return count
end

emu.addEventCallback(function()
  emu.setInput({start = frames < 10, a = wantFire}, 0)
end, emu.eventType.inputPolled)

pcall(function()
  emu.addMemoryCallback(function(_addr, value)
    if value == 0x24 then enemySounds = enemySounds + 1 end
  end, emu.callbackType.write, 0x400F)
end)

emu.addEventCallback(function()
  frames = frames + 1
  MT = emu.memType.nesDebug
  if frames > 800 then return fail("timed out in " .. state) end

  if state == "boot" and frames == 80 then
    for _, thing in ipairs({18, 19, 26, 35}) do
      if emu.read(THING_HEALTH + thing, MT) ~= 20 then
        return fail("zombieman health was not initialized")
      end
    end
    if read16(MONSTER_X_LO) == 0 or read16(MONSTER_Y_LO) == 0 then
      return fail("mutable zombieman coordinates were not initialized")
    end
    -- Stand west of the nearer zombieman in its large room and face east.
    write16(0x30, 0x60E0)
    write16(0x32, 0x2400)
    write16(0x34, 0x0000)
    emu.write(0x6A05, 200, MT)
    emu.write(0x6A06, 100, MT)
    emu.write(0x6A07, 2, MT)
    emu.write(MONSTER_LAST_ATTACK + SLOT, emu.read(0x00, MT), MT)
    startX = read16(MONSTER_X_LO + SLOT)
    state = "approach"
    stateAt = frames

  elseif state == "approach" and frames - stateAt >= 40 then
    local x = read16(MONSTER_X_LO + SLOT)
    if x >= startX then return fail("zombieman did not pursue the player") end
    local rows = enemyOamRows()
    if rows < 2 then
      return fail(string.format("zombieman produced no world OAM at %04X:%04X ss=%d",
        read16(MONSTER_X_LO + SLOT), read16(MONSTER_Y_LO + SLOT),
        emu.read(0x6AE2 + SLOT, MT)))
    end
    state = "wait_damage"
    stateAt = frames

  elseif state == "wait_damage" and emu.read(ENEMY_HITS, MT) > 0 then
    if emu.read(ENEMY_ATTACKS, MT) == 0 or enemySounds == 0 then
      return fail("enemy attack had no report")
    end
    if emu.read(0x6A05, MT) >= 200 and emu.read(0x6A06, MT) >= 100 then
      return fail("enemy hit did not damage health or armor")
    end
    -- Make the next valid pistol hit lethal regardless of its 5/10/15 roll.
    emu.write(THING_HEALTH + TARGET, 5, MT)
    state = "ready_fire"
    stateAt = frames

  elseif state == "ready_fire" and emu.read(WEAPON_FRAME, MT) == 0 and
         emu.read(WEAPON_TIMER, MT) == 0 then
    wantFire = true
    state = "kill"
    stateAt = frames

  elseif state == "kill" then
    if emu.read(THING_HEALTH + TARGET, MT) == 0 then
      wantFire = false
      if emu.read(ZOMBIE_KILLS, MT) ~= 1 then return fail("kill was not counted") end
      if emu.read(THING_HEALTH + OTHER, MT) ~= 20 then
        return fail("pistol did not choose the nearer zombieman")
      end
      if not active(TARGET) then return fail("death removed zombieman immediately") end
      deathAt = emu.read(THING_DEATH_AT + TARGET, MT)
      deathX = read16(MONSTER_X_LO + SLOT)
      deathY = read16(MONSTER_Y_LO + SLOT)
      state = "dying"
      stateAt = frames
    elseif frames - stateAt > 100 then
      return fail("pistol did not kill centered zombieman")
    end

  elseif state == "dying" then
    local age = (emu.read(0x00, MT) - deathAt) % 256
    if age >= 24 and active(TARGET) then
      if read16(MONSTER_X_LO + SLOT) ~= deathX or
         read16(MONSTER_Y_LO + SLOT) ~= deathY then
        return fail("dead zombieman kept moving")
      end
      if enemyOamRows() == 0 then return fail("death frames produced no OAM") end
    end
    if not active(TARGET) then
      if age < 96 then return fail("zombieman expired too early") end
      print(string.format(
        "M9 PASS (attacks=%d hits=%d sounds=%d deathAge=%d)",
        emu.read(ENEMY_ATTACKS, MT), emu.read(ENEMY_HITS, MT), enemySounds, age))
      emu.stop(0)
    end
  end
end, emu.eventType.endFrame)
