-- The worked example from docs/pickles.md. Every global function here is an
-- action: POST /api/pickles/hello/call/<name> with a JSON array of arguments.

-- Globals persist between calls while the pickle runs; storage persists
-- across restarts too.
uptime_ticks = 0

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
    name = mayo.name,
    version = mayo.version
  }
end
