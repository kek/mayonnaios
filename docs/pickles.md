> **Documentation for current `trunk`; installed firmware may differ.**

# Pickles: writing and deploying sandboxed Lua apps

**Status: Verified.** Pickles are sandboxed Lua apps that run inside
MayonnaiOS on the BEAM. They can be headless background agents or, with the
`ui` capability, appear in the launcher's Apps column and draw on the panel.
Typical uses include controlling a LAN lamp, polling a web API, remembering
state, or running a timed action.

Pickles are *content*, like games and cores: installed over the network,
never part of a firmware build.

## Prerequisites

- MayonnaiOS and an authoring computer are on the same trusted LAN.
- `tar` and `curl` are available on the authoring computer.
- The unauthenticated-device trust boundary described under Deploying is
  acceptable for that network.
- Start from the complete `pickles/hello/` example when testing the pipeline.

## The shape of a pickle

A pickle is a directory with a manifest and a script, shipped as a `.tar.gz`:

    tuya-lamps/
      pickle.json
      main.lua

`pickle.json`:

```json
{
  "name": "tuya-lamps",
  "version": "1.0.0",
  "description": "Control the living room lamps",
  "main": "main.lua",
  "capabilities": ["lan", "storage", "timers"],
  "autostart": true
}
```

- `name` -- required; 1–32 characters, beginning with a lowercase letter or
  digit, then lowercase letters, digits, `-`, or `_`; must match the name it is
  installed under.
- `version` -- optional; exposed as `mayo.version`, default `"0"`.
- `description` -- optional; shown as pickle metadata, default empty.
- `capabilities` -- optional, default `[]`; what the sandbox will grant. Anything not listed simply
  does not exist inside the script. Unknown names fail the install.
  Known: `http`, `lan`, `storage`, `timers`, `ui`.
- `hosts` -- optional list of hostnames; when present, `http` is limited to
  exactly these.
- `autostart` -- optional boolean, default `false`; start at boot and right
  after install.
- `main` -- optional plain filename, default `"main.lua"`.

## The script's life

The chunk runs once when the pickle starts. Then:

- `on_start()`, if defined, is called.
- Any **global function** the script defines is an *action*, callable over
  the web API and from the console.
- Functions named in `mayo.timer.every/once` are called on the clock.

State lives in globals between calls -- the Lua VM stays alive as long as
the pickle runs. Anything that must survive a restart goes in
`mayo.storage`.

Every piece of Lua runs with a wall-clock budget (30 s) and a memory cap.
An infinite loop or a memory bomb kills that one call, never the pickle,
never the device.

## The `mayo` API

Failure convention throughout: success returns the result; failure returns
`nil, "reason"`. Nothing raises.

### Always available

| | |
|---|---|
| `mayo.name`, `mayo.version` | from the manifest |
| `mayo.log(msg)` | into the pickle's log (`GET /api/pickles/<name>/log`) and the system log |
| `mayo.sleep(ms)` | capped at 10 s |
| `mayo.now_ms()` | wall clock, milliseconds |
| `mayo.json.encode(value)` | table/number/string/bool → JSON string |
| `mayo.json.decode(s)` | JSON string → value (objects become tables) |

### `"http"` -- the internet

| | |
|---|---|
| `mayo.http.get(url [, headers])` | → `body, status` |
| `mayo.http.post(url, body [, headers])` | → `body, status` |
| `mayo.http.request(method, url [, body [, headers]])` | → `body, status` |

`headers` is a table like `{["Authorization"] = "Bearer x"}`. Responses are
capped at 1 MB, requests time out after 10 s. If the manifest has `hosts`,
other hosts answer `nil, "http: host not in this pickle's allowlist"`.

### `"lan"` -- raw sockets, local addresses only

| | |
|---|---|
| `mayo.lan.tcp(host, port, data [, timeout_ms])` | connect, send, return whatever arrives before close/timeout (may be `""`) |
| `mayo.lan.udp(host, port, data)` | one datagram, fire and forget → `true` |
| `mayo.lan.udp_request(host, port, data [, timeout_ms])` | one datagram, one reply |

Destinations must resolve to loopback, link-local or RFC 1918 addresses;
the internet answers `nil, "lan: :not_local"`. Payloads ≤ 64 KB, timeouts
≤ 10 s (default 2 s). Framing is the script's problem -- `tcp` returns the
bytes that arrived, it does not know where your protocol's messages end.

### `"storage"` -- a KV store that survives restarts and reinstalls

| | |
|---|---|
| `mayo.storage.set(key, value)` | value is anything JSON-shaped |
| `mayo.storage.get(key)` | → value or `nil` |
| `mayo.storage.delete(key)` | → `true` |

Capped at 64 KB total. Deleted when the pickle is deleted, kept when it is
reinstalled or upgraded.

### `"timers"` -- callbacks on a clock

| | |
|---|---|
| `mayo.timer.every(ms, "fname")` | call the global `fname` repeatedly |
| `mayo.timer.once(ms, "fname")` | call it once |

Intervals are clamped to ≥ 250 ms; at most 16 timers. A callback that
errors is logged and the timer keeps ticking -- an unreachable lamp should
be retried, and a repeating log line is a report.

### `"ui"` -- a face on the panel

A pickle with `ui` appears as a row in the launcher's Apps column.
Pressing A puts
its face on the screen; Menu takes the face off -- **the pickle keeps
running** either way, because a ui pickle is still a background app, just
one you can look at.

The face is two functions the script defines:

```lua
count = 0

function on_button(button, pressed)
  if pressed and button == "a" then count = count + 1 end
end

function on_draw()
  return {
    {kind = "rect", x = 0, y = 0, w = mayo.ui.width, h = mayo.ui.height, color = "black"},
    {kind = "text", x = 40, y = 60, text = "pressed " .. count, size = 32, color = "yellow"},
  }
end
```

- `on_draw()` returns a *display list*: an array of tables, each
  `{kind = "text" | "rect" | "line" | "circle", ...}`. Text takes `x, y,
  text, size, color`; rect `x, y, w, h, color, fill`; line `x1, y1, x2, y2,
  color, width`; circle `x, y, r, color, fill`. Colors are names from a
  fixed palette (`white black red green blue yellow orange purple cyan
  magenta gray brown pink lime navy teal gold`, plus `dark_gray` and
  `light_gray`); anything else renders white. Invalid entries are counted
  on screen rather than silently dropped. At most 256 ops per frame.
  `on_draw` should not change state -- what it computes beyond the return
  value is discarded.
- `on_button(button, pressed)` gets the names on the plastic: `a b x y up
  down left right l1 r1 l2 r2 select start`, with `pressed` true on press
  and false on release. Menu never arrives -- it is how the player leaves.

The panel repaints after every button, action call and timer tick, and
whenever the script asks with `mayo.ui.redraw()`. `mayo.ui.width` and
`mayo.ui.height` are the panel size (640x480).

### What is not there

`io`, `os.execute`, `require`, `load`, `package`, files, spawning -- the
stock Lua escape hatches are stripped by the sandbox. There is no way to a
shell from inside a pickle; the `mayo` tables are the entire world.

## Deploying

Package (both layouts work -- files at the top level or inside one
directory):

    tar -czf tuya-lamps.tar.gz -C tuya-lamps .

Then, against the device (no auth, same trust model as the upload page):

    curl -T tuya-lamps.tar.gz http://nerves.local/api/pickles/tuya-lamps

The upload body is capped at 5 MB. Action-call JSON bodies are capped at 64,000
bytes, and each running pickle keeps its 200 most recent log entries.

Installing stops a running copy, swaps the code, and starts it again (or
starts it fresh if `autostart` is set). Deploying an iteration is that one
`curl` line.

**Success:** the PUT returns the installed manifest, the pickle appears in
`GET /api/pickles`, and its `running` value is true when it was already running
or requests `autostart`. A `ui` pickle also appears under **Apps**; a headless
pickle does not need a launcher row.

The rest of the API:

    GET    /api/pickles                       what is installed, what is running
    POST   /api/pickles/<name>/start
    POST   /api/pickles/<name>/stop
    POST   /api/pickles/<name>/call/<fn>      body: JSON array of arguments
    GET    /api/pickles/<name>/log            status + recent log
    DELETE /api/pickles/<name>                also deletes its storage

Calling an action:

    curl -X POST http://nerves.local/api/pickles/tuya-lamps/call/set_lamp \
         -d '["living-room", true]'
    {"results":[true]}

From the console, the same things:

    iex> MayonnaiOS.Pickles.list()
    iex> MayonnaiOS.Pickles.call("tuya-lamps", "set_lamp", ["living-room", true])
    iex> MayonnaiOS.Pickles.info("tuya-lamps").log

## A worked example

`pickles/hello/` in this repository is a complete pickle that exercises
most of the API: an action with arguments, a timer, storage, logging. It is
also the smoke test for the whole pipeline:

    tar -czf hello.tar.gz -C pickles/hello .
    curl -T hello.tar.gz http://nerves.local/api/pickles/hello
    curl -X POST http://nerves.local/api/pickles/hello/call/greet -d '["world"]'

## Troubleshooting and status limitations

- **Upload is refused:** confirm the URL name matches `pickle.json`, `main` is
  a plain filename, the archive has one supported layout, and every capability
  is one of `http`, `lan`, `storage`, `timers`, or `ui`.
- **A `mayo` table is nil:** add its capability to the manifest and redeploy;
  omitted capabilities are intentionally absent.
- **A call times out or runs out of memory:** inspect the recent log. The
  30-second call budget and heap cap kill that call while preserving the
  runner's previous Lua state.
- **A UI row is absent:** include `"ui"`, install successfully, and refresh the
  launcher. Headless Pickles intentionally have no row.
- **LAN/HTTP fails:** `lan` permits only local addresses; `http` may be narrowed
  by `hosts`. Payload, response, and timeout limits in this reference still
  apply.
- **Device is not reachable:** follow [Connect to WiFi](wifi.md). The Pickles
  HTTP API has no authentication; never expose it to an untrusted LAN.

## Design notes

Why Luerl (Lua-in-Erlang) and not a second OS process: a pickle is a
GenServer, so it costs nothing at idle, cannot leave a zombie holding a
device node, and is inspectable from the console like everything else. The
sandbox is capability-based and default-deny: the manifest's `capabilities`
list is the complete statement of what a pickle can reach, which makes it
reviewable at install time -- read two lines of JSON, know the blast
radius. Module-level detail lives in `MayonnaiOS.Pickles`,
`MayonnaiOS.Pickles.Store`, `MayonnaiOS.Pickles.Sandbox`,
`MayonnaiOS.Pickles.Runner`, `MayonnaiOS.Pickles.Lan`, and
`MayonnaiOS.Pickles.Frame`. Advanced console calls are covered in
[SSH and IEx](ssh-and-iex.md); installed paths are listed in
[On-device data layout](data-layout.md).

[Edit this page](https://github.com/kek/mayonnaios/edit/trunk/docs/pickles.md) ·
[Report a documentation issue](https://github.com/kek/mayonnaios/issues/new)
