# Pickles: writing and deploying sandboxed Lua apps

A pickle is a small Lua program that runs inside MayonnaiOS -- in the BEAM,
sandboxed, with no screen of its own. It is the kind of app that turns the
handheld into a remote control or a background agent: poke a lamp on the
local network, poll a web API, remember things, do something every minute.

Pickles are *content*, like games and cores: installed over the network,
never part of a firmware build.

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

- `name` -- required; lowercase letters, digits, `-`, `_`; must match the
  name it is installed under.
- `capabilities` -- what the sandbox will grant. Anything not listed simply
  does not exist inside the script. Unknown names fail the install.
  Known: `http`, `lan`, `storage`, `timers`.
- `hosts` -- optional list of hostnames; when present, `http` is limited to
  exactly these.
- `autostart` -- start at boot, and right after install.
- `main` -- defaults to `"main.lua"`.

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

Installing stops a running copy, swaps the code, and starts it again (or
starts it fresh if `autostart` is set). Deploying an iteration is that one
`curl` line.

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

## Design notes

Why Luerl (Lua-in-Erlang) and not a second OS process: a pickle is a
GenServer, so it costs nothing at idle, cannot leave a zombie holding a
device node, and is inspectable from the console like everything else. The
sandbox is capability-based and default-deny: the manifest's `capabilities`
list is the complete statement of what a pickle can reach, which makes it
reviewable at install time -- read two lines of JSON, know the blast
radius. Module-level detail lives in the moduledocs: `MayonnaiOS.Pickles`,
`.Store`, `.Sandbox`, `.Runner`, `.Lan`.
