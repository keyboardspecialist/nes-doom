-- M15: full-map pickups, static LOS blockers, lift, and exit behavior.
local frames = 0
local state = "boot"
local stateAt = 0
local MT = nil
local wantUse = false
local attacksBefore = 0
local pickupBitsBefore = 0

local function fail(msg)
  print("M15 FAIL: " .. msg)
  emu.stop(1)
end

local function write16(address, value)
  emu.write(address, value % 256, MT)
  emu.write(address + 1, math.floor(value / 256), MT)
end

local function monster16(base, slot, value)
  emu.write(base + slot, value % 256, MT)
  emu.write(base + 8 + slot, math.floor(value / 256), MT)
end

emu.addEventCallback(function()
  emu.setInput({start = frames < 10, b = wantUse,
                up = state == "pickup_move" or state == "lift_start"}, 0)
end, emu.eventType.inputPolled)

emu.addEventCallback(function()
  frames = frames + 1
  MT = emu.memType.nesDebug
  if frames > 1400 then return fail("timed out in " .. state) end

  if state == "boot" and frames == 80 then
    -- Move onto the last full-map item. Successful collision checks switch the
    -- banked $A000 window, so collection must restore the common metadata bank.
    emu.write(0x6A05, 50, MT)
    pickupBitsBefore = emu.read(0x6A0F, MT)
    write16(0x30, 0x6380); write16(0x32, 0x0666)
    write16(0x34, 0x0000)
    state = "pickup_move"
    stateAt = frames

  elseif state == "pickup_move" then
    local x = emu.read(0x30, MT) + 256 * emu.read(0x31, MT)
    if x >= 0x6500 then
      state = "pickup_verify"
      stateAt = frames
    elseif frames - stateAt > 180 then
      return fail("could not move through full-map stimpack")
    end

  elseif state == "pickup_verify" then
    if frames - stateAt > 30 then
      local pickupBits = emu.read(0x6A0F, MT)
      if math.floor(pickupBits / 128) % 2 ~= 0 then
        return fail("moving through full-map stimpack did not collect it")
      end
      if emu.read(0x6A05, MT) ~= 60 or emu.read(0x6A2C, MT) ~= 1 then
        return fail("full-map stimpack reward was not applied exactly once")
      end
      if pickupBits ~= pickupBitsBefore - 0x80 then
        return fail(string.format("stimpack active bits changed %02X -> %02X",
          pickupBitsBefore, pickupBits))
      end

      -- Keep only monster slot 0 alive and place it across the closed start door.
      for slot = 1, 5 do
        local thing = ({21, 29, 30, 44, 46})[slot]
        emu.write(0x6A2D + thing, 0, MT)
      end
      write16(0x30, 0x3C66); write16(0x32, 0x3F33)
      monster16(0x6AC2, 0, 0x3F33); monster16(0x6AD2, 0, 0x3F33)
      emu.write(0x6AF2, (emu.read(0x00, MT) - 64) % 256, MT)
      emu.write(0x6A05, 200, MT)
      attacksBefore = emu.read(0x6AFC, MT)
      state = "closed_los"
      stateAt = frames
    end

  elseif state == "closed_los" then
    emu.write(0x6AEA, emu.read(0x00, MT), MT) -- hold monster position
    if frames - stateAt == 100 then
      if emu.read(0x6AFC, MT) ~= attacksBefore then
        return fail("enemy attacked through closed door")
      end
      emu.write(0x7820, 1, MT)
      emu.write(0x6AF2, (emu.read(0x00, MT) - 64) % 256, MT)
      state = "open_los"
      stateAt = frames
    end

  elseif state == "open_los" then
    emu.write(0x6AEA, emu.read(0x00, MT), MT)
    if emu.read(0x6AFC, MT) > attacksBefore then
      emu.write(0x6A2D + 20, 0, MT)
      write16(0x30, 0x6050); write16(0x32, 0x3400)
      write16(0x34, 0x0000)
      state = "lift_start"
      stateAt = frames
    elseif frames - stateAt > 140 then
      return fail("enemy did not attack through open door")
    end

  elseif state == "lift_start" then
    if emu.read(0x782E, MT) ~= 0 then
      state = "lift_down"
      stateAt = frames
    elseif frames - stateAt > 180 then
      return fail(string.format("walk trigger did not start lift at %04X:%04X",
        emu.read(0x30, MT) + 256 * emu.read(0x31, MT),
        emu.read(0x32, MT) + 256 * emu.read(0x33, MT)))
    end

  elseif state == "lift_down" then
    if emu.read(0x7946, MT) == 0xED and emu.read(0x782E, MT) == 2 then
      if emu.read(0x7824, MT) ~= 1 then return fail("lowered lift is not passable") end
      write16(0x30, 0x60CD); write16(0x32, 0x0666)
      write16(0x34, 0x8000)
      wantUse = true
      state = "exit"
      stateAt = frames
    elseif frames - stateAt > 500 then
      return fail("lift never reached lower floor")
    end

  elseif state == "exit" then
    if frames - stateAt > 3 then wantUse = false end
    if emu.read(0x16, MT) == 0x87 and frames - stateAt > 5 then
      print("M15 PASS (moving pickup, closed/open LOS, lift, exit-to-title)")
      emu.stop(0)
    elseif frames - stateAt > 120 then
      return fail("exit switch did not return to title")
    end
  end
end, emu.eventType.endFrame)
