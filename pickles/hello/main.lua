-- The worked example from docs/pickles.md. Every global function here is an
-- action: POST /api/pickles/hello/call/<name> with a JSON array of arguments.
-- With the "ui" capability it is also a row on the launcher menu; A counts
-- presses, Menu goes back.

-- Globals persist between calls while the pickle runs; storage persists
-- across restarts too.
uptime_ticks = 0
presses = 0

function on_start()
  local visits = (mayo.storage.get("visits") or 0) + 1
  mayo.storage.set("visits", visits)
  mayo.log("hello pickle started, boot number " .. visits)

  mayo.timer.every(60000, "tick")
end

function tick()
  uptime_ticks = uptime_ticks + 1
end

-- curl -X POST http://nerves.local/api/pickles/hello/call/greet -d '["world"]'
function greet(who)
  return "hello " .. (who or "there")
end

-- curl -X POST http://nerves.local/api/pickles/hello/call/status
function status()
  return {
    boots = mayo.storage.get("visits"),
    minutes_up = uptime_ticks,
    presses = presses,
    name = mayo.name,
    version = mayo.version
  }
end

-- The face: on the launcher, press A on the "hello" row.
function on_button(button, pressed)
  if pressed and button == "a" then
    presses = presses + 1
  end
end

function on_draw()
  return {
    {kind = "rect", x = 0, y = 0, w = mayo.ui.width, h = mayo.ui.height, color = "black"},
    {kind = "text", x = 40, y = 70, text = "hello, this is a pickle", size = 32, color = "yellow"},
    {kind = "line", x1 = 40, y1 = 90, x2 = 600, y2 = 90, color = "gray"},
    {kind = "text", x = 40, y = 140, text = "boot number " .. (mayo.storage.get("visits") or 0), size = 24},
    {kind = "text", x = 40, y = 180, text = "minutes up " .. uptime_ticks, size = 24},
    {kind = "text", x = 40, y = 220, text = "A pressed " .. presses .. " times", size = 24, color = "cyan"},
    {kind = "circle", x = 320, y = 340, r = 24 + math.min(presses, 60), color = "green", fill = false},
    {kind = "text", x = 40, y = 460, text = "A counts, Menu goes back", size = 16, color = "gray"},
  }
end
