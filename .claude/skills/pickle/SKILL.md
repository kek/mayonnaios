---
name: pickle
description: Use when the user wants a MayonnaiOS pickle (a sandboxed Lua scriptapp) developed, changed, or deployed onto the handheld — "make me a pickle that controls my tuya lamps", "a scriptapp that shows the weather", "update the lamps pickle". Covers authoring the Lua, choosing capabilities, packaging, deploying to the device over HTTP, and the verify/iterate loop.
---

# Developing and deploying a pickle

A pickle is a sandboxed Lua app running inside MayonnaiOS on the handheld.
Full reference: `docs/pickles.md`. Working example: `pickles/hello/`.
Engine source: `lib/mayonnaios/pickles*` — read `Sandbox` if unsure what an
API function returns.

## The loop

1. **Find the device.** Default `http://nerves.local`; the user may give
   another host. Verify with `curl -s http://nerves.local/api/pickles` —
   it also tells you what is already installed and running. If unreachable,
   stop and ask; nothing else works without it.

2. **Scaffold in the repo** under `pickles/<name>/` (lowercase, digits,
   `-`, `_`; ≤32 chars) so the source is versioned: `pickle.json` +
   `main.lua`.

3. **Request the minimum capabilities.** The manifest's `capabilities`
   list is the sandbox contract and unknown names fail the install:
   - `http` — internet requests; add `"hosts": [...]` to pin the APIs used
   - `lan` — raw TCP/UDP to private addresses (lamps, hubs, TVs)
   - `storage` — KV that survives restarts and reinstalls
   - `timers` — periodic callbacks
   - `ui` — a face on the panel: the pickle becomes a launcher menu row.
     Define `on_draw()` returning a display list (`{kind="text"|"rect"|
     "line"|"circle", ...}`, named colors, 640×480) and `on_button(button,
     pressed)` with plastic names (`a b x y up down left right l1 r1 l2 r2
     select start`; Menu never arrives — it exits). Repaint is automatic
     after buttons/actions/timers, or on `mayo.ui.redraw()`. `on_draw` must
     not change state. Full contract in `docs/pickles.md`.
   Set `"autostart": true` for anything meant to be running by default —
   it also makes every deploy start the new code immediately.

4. **Write the Lua.** Rules of the runtime:
   - The chunk runs once at start; `on_start()` is called if defined.
   - Every global function is an action callable over HTTP.
   - Globals persist between calls; `mayo.storage` persists across restarts.
   - Every `mayo.*` call returns `result` or `nil, "reason"` — check the
     second value, nothing raises.
   - Stripped: `io`, `os.execute`, `require`, `load`, files. Use `mayo.*`.
   - Each call has 30 s and a memory cap; a busy loop kills the call only.

   API in brief (details in `docs/pickles.md`):
   `mayo.log(msg)`, `mayo.sleep(ms)`, `mayo.now_ms()`,
   `mayo.json.encode/decode`,
   `mayo.http.get(url[,headers])` / `.post(url,body[,headers])` /
   `.request(method,url[,body[,headers]])` → `body, status`,
   `mayo.lan.tcp(host,port,data[,timeout_ms])` → reply bytes,
   `mayo.lan.udp(host,port,data)`, `mayo.lan.udp_request(...)`,
   `mayo.storage.get/set/delete`,
   `mayo.timer.every(ms,"fname")` / `.once(ms,"fname")` (≥250 ms, ≤16).

5. **Sanity-check on the host before touching the device.** The engine
   runs on a laptop (`pickles_root` is `.pickles` there), and the laptop is
   on the same LAN as the lamps, so this exercises the real script against
   the real device without a deploy:

   ```
   $ tar -czf /tmp/NAME.tar.gz -C pickles/NAME .
   $ iex -S mix
   iex> MayonnaiOS.Pickles.install("NAME", "/tmp/NAME.tar.gz")   # starts it if autostart
   iex> MayonnaiOS.Pickles.start("NAME")                         # otherwise
   iex> MayonnaiOS.Pickles.call("NAME", "FN", ["arg"])
   iex> MayonnaiOS.Pickles.info("NAME")                          # status + log
   ```

6. **Package and deploy** — one PUT swaps a running pickle for the new code:

   ```sh
   tar -czf /tmp/NAME.tar.gz -C pickles/NAME .
   curl -sf -T /tmp/NAME.tar.gz http://nerves.local/api/pickles/NAME
   ```

7. **Verify on the device, then iterate:**

   ```sh
   curl -s http://nerves.local/api/pickles                      # running?
   curl -s -X POST http://nerves.local/api/pickles/NAME/call/FN -d '[ARGS]'
   curl -s http://nerves.local/api/pickles/NAME/log             # status + log
   ```

   A load failure shows as `"status":{"error":...}` in the log endpoint
   with the Lua compile/runtime error. Fix, re-tar, re-PUT — that is the
   whole cycle. Do not declare success until an actual action call against
   the device returned the expected result.

8. **Commit the pickle source** in the repo once it works.

## Device-protocol work (lamps, hubs, TVs)

- Ask the user for what only they know: device IPs, local keys, hub tokens.
  Tuya local control, for example, needs each device's `local_key` (from
  the Tuya IoT platform) — do not pretend to control a lamp without it.
- Prefer a hub/bridge HTTP API (`lan` or `http` to a private address) over
  reimplementing an encrypted binary protocol in Lua. Tuya's local
  protocol 3.3+ is AES-encrypted; that is heavy for a pickle, so steer to
  Zigbee2MQTT/Home Assistant/the hub's own API when one exists.
- `mayo.lan.tcp` returns whatever bytes arrived before timeout/close;
  message framing is the script's job.
- Store discovered device state (IPs, ids) in `mayo.storage`, not in
  globals, so it survives restarts.

## Pitfalls

- Arguments to `/call/FN` must be a **JSON array**, one element per Lua
  argument.
- JSON objects become Lua tables with string keys; arrays are 1-indexed.
- A pickle that is installed but not started answers 409 — start it or set
  `autostart`.
- `hosts` in the manifest gates `http` only; `lan` is gated by "private
  address" instead.
- The device web API has no auth (home-network trust model) — never expose
  it beyond the LAN, and put secrets in `mayo.storage` via an action call
  rather than hardcoding them in committed Lua.
