> **Documentation for current `trunk`; installed firmware may differ.**

# Develop on the host

The host profile runs tests and the MayonnaiOS UI without an RG40XXV. It is a
fast development loop, not evidence that display drivers, radios, power use, or
other hardware behavior works on the handheld.

## Prerequisites

- Elixir `~> 1.20` and a compatible Erlang/OTP.
- Git and the dependencies fetched by Mix.
- The native prerequisites used by `scenic_driver_local`: GTK 3, Cairo, and
  `pkgconf`; macOS also needs XQuartz. On Debian/Ubuntu, install
  `build-essential`, `libcairo2-dev`, `libfreetype6-dev`, `libgtk-3-dev`,
  `libsystemd-dev`, and `pkg-config`.

Use `MIX_TARGET=host` explicitly in scripts and documentation work. An unset
target currently defaults to host, but the explicit value prevents a target
shell from leaking into the command.

## Run the tests

**Context: MayonnaiOS repository on the host; no firmware credentials or device.**

```console
$ MIX_TARGET=host mix test
```

**Success:** the ExUnit suite exits successfully. The test environment is
headless: it does not start Scenic, the launcher, keyboard bridge, web server,
or host-runtime children. Hardware-facing tests use substitutions and establish
Elixir behavior, not physical effects.

## Start the complete host runtime

**Context: MayonnaiOS repository on a graphical host with the GTK/Cairo
prerequisites.**

```console
$ MIX_TARGET=host iex -S mix
```

In the `:dev` environment this starts a fixed 640×480 Scenic window, the real
launcher and Elixir/Luerl app supervisors, a keyboard-to-evdev bridge, and the
web UI at <http://localhost:4000/>. A short shell command stands in for an
external KMS program, so launcher handoff can be exercised without installing
RetroArch or Moonlight.

**Success:** the launcher window appears, keyboard navigation changes the real
launcher selection, and the web page responds. A scene that merely looks right
at another window size is not evidence about the fixed 640×480 panel; even this
correctly sized host window is not handheld verification.

Host state is intentionally disposable and gitignored:

- `tmp/host/files/` is the Files-column scratch root.
- `tmp/host/brightness` substitutes for the backlight control.
- `.pickles/` receives the worked `pickles/hello` example on first run.

## Edit and reload a scene

`recompile/0` loads new code, but an existing scene process still holds its
already-built graph. Restart the root scene to render the edit.

**Context: the running host IEx session.**

```elixir
recompile()
MayonnaiOS.reload_ui()
```

Pass the documented scene/arguments to `MayonnaiOS.reload_ui/2` when working on
a different root. Scenic may log that the replaced scene exited with
`:shutdown`; during an intentional root replacement, that message is expected.

**Success:** the root scene restarts and the window shows the changed graph.

## Keyboard mapping

The bridge emits the same evdev-shaped reports consumed on the device.

| Host key | Handheld input or action |
|---|---|
| arrows or `h` `j` `k` `l` | D-pad |
| `z` | A / open or launch |
| `x` | B / back |
| `c` | X |
| `v` | Y / actions |
| `b`, `f` | L1, R1 / page |
| `s` | Start |
| Enter | Menu / home |
| Backspace | Select |
| `p` | Power button / sleep; any key wakes |
| Escape | Select+Menu orderly-poweroff chord |

The mappings are not host-conditional: a USB keyboard seen by Scenic on the
handheld uses the same bridge. See `MayonnaiOS.Keyboard` for the exact report
mapping and `MayonnaiOS.Dev` for scriptable button helpers.

## Troubleshooting

- **Native compilation fails:** install the GTK 3, Cairo, `pkgconf`, compiler,
  and systemd development prerequisites listed above; on macOS ensure XQuartz
  is installed and available. Host docs compilation uses these same existing
  prerequisites too.
- **No window in `mix test`:** expected; tests are deliberately headless.
- **Code recompiles but the view is unchanged:** run
  `MayonnaiOS.reload_ui/0` after `recompile/0`.
- **Port 4000 is occupied:** stop the other service or change the host-only
  `:web_port` while developing.
- **Need isolated files:** use `tmp/host/files/`; do not point experiments at
  device-style absolute paths on the host.

For documentation and review requirements, continue with
[Contributing](contributing.md). For hardware claims, use the
[RG40XXV status matrix](hardware-status.md).

[Edit this page](https://github.com/kek/mayonnaios/edit/trunk/docs/development.md) ·
[Report a documentation issue](https://github.com/kek/mayonnaios/issues/new)
