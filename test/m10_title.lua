-- M10: WAD TITLEPIC remains active until Start, then restores gameplay state.
local frames = 0
local MT = nil

local function fail(msg)
  print("M10 FAIL: " .. msg)
  emu.stop(1)
end

emu.addEventCallback(function()
  emu.setInput({start = frames >= 90 and frames < 100}, 0)
end, emu.eventType.inputPolled)

emu.addEventCallback(function()
  frames = frames + 1
  MT = emu.memType.nesDebug
  if frames == 60 then
    if emu.read(0x00, MT) ~= 0 then return fail("NMI ran on title") end
    if emu.read(0x08, MT) ~= 0 then return fail("game loop started before Start") end
    if emu.read(0x0A, MT) ~= 0xA5 then return fail("ExRAM self-test state lost") end
    if emu.read(0x16, MT) ~= 0x87 then return fail("title PRG bank not selected") end
    local colors = {}
    local screen = emu.getScreenBuffer()
    local border = screen[1]
    for y = 0, 19 do
      for x = 0, 255 do
        if screen[y * 256 + x + 1] ~= border then return fail("top title border is not blank") end
      end
    end
    for y = 220, 239 do
      for x = 0, 255 do
        if screen[y * 256 + x + 1] ~= border then return fail("bottom title border is not blank") end
      end
    end
    for y = 20, 219 do
      for x = 0, 255 do colors[screen[y * 256 + x + 1]] = true end
    end
    local count = 0
    for _ in pairs(colors) do count = count + 1 end
    if count < 6 then return fail("TITLEPIC did not render") end
  elseif frames == 150 then
    if emu.read(0x00, MT) < 30 then return fail("gameplay NMI did not start") end
    if emu.read(0x08, MT) == 0 then return fail("game loop did not start") end
    if emu.read(0x09, MT) == 0 then return fail("scanline IRQ did not start") end
    if emu.read(0x16, MT) ~= 0x80 then return fail("gameplay PRG bank not restored") end
    print("M10 PASS (TITLEPIC waits for Start and restores gameplay)")
    emu.stop(0)
  elseif frames > 180 then
    return fail("timed out")
  end
end, emu.eventType.endFrame)
