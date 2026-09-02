> **Documentation for current `trunk`; installed firmware may differ.**

# Use SSH and IEx for advanced tasks

**Status: Verified** over WiFi. SSH/IEx is an advanced and sometimes-required
interface, not the primary owner path. WiFi is currently the only remote access
observed on RG40XXV hardware; USB gadget recovery is **Untested**.

## Prerequisites

- The firmware was built with your SSH public key in `~/.ssh`.
- The handheld is connected to the same network and shows an address under
  **System → WiFi**.
- Use `nerves.local` only when one such device advertises that name; otherwise
  use its unique hostname or address.

## Connect and inspect logs

```console
$ ssh nerves.local
```

A normal connection opens an IEx prompt rather than a general shell. Confirm the
application responds, then read buffered or live logs:

```elixir
MayonnaiOS.SystemInfo.panel()
RingLogger.next()
RingLogger.attach()
```

Exit the prompt normally when finished. If the hostname does not resolve, use
the address shown on the panel. If authentication fails, the required public key
was not included in that firmware and recovery may require rebuilding/reflashing.

## Bundles, cores, and libraries

Use browser/panel paths first; these calls are useful for diagnosis and recovery:

```elixir
MayonnaiOS.Bundle.install(MayonnaiOS.Bundle.spec(:retroarch))
MayonnaiOS.Cores.list()
MayonnaiOS.Cores.install(:snes9x2010)
MayonnaiOS.Cores.sync()
MayonnaiOS.Library.index()
MayonnaiOS.GamesCard.mounted?()
MayonnaiOS.GamesCard.unmount()
```

Always stop a game and wait for `MayonnaiOS.GamesCard.unmount/0` to return
`:ok` before removing the second card. The [games guide](games-and-cores.md),
[files guide](files-and-storage.md), and linked API pages own the contracts; do
not infer success from a process merely starting.

## Bluetooth diagnosis and recovery

Only one Bluetooth app can own `hci0`:

```elixir
MayonnaiOS.Controller.status()
MayonnaiOS.Controller.stop()
MayonnaiOS.Pairing.start()
MayonnaiOS.Pairing.status()
MayonnaiOS.Pairing.stop()
```

`:eusers` means another Bluetooth session owns the controller. If startup returns
`:enodev` after its automatic one-shot recovery, try the verified manual rebind
once:

```elixir
MayonnaiOS.Bluetooth.Serdev.revive()
```

Then restart the intended app. See [Bluetooth internals](bluetooth-internals.md)
for the unexplained intermittent bring-up limitation and do not create an
unbounded retry loop.

To clear controller pairing, forget `Xbox Wireless Controller` on the host and
call `MayonnaiOS.Controller.unpair/0` while controller mode is running. Both
sides must be cleared.

## Moonlight pairing exception

The panel writes Moonlight settings, but pairing prints a PIN for entry on the
host. At the SSH IEx prompt, run the bundle executable while streaming its output:

```elixir
System.cmd(
  "/root/bundles/moonlight/current/bin/moonlight",
  ["pair", "<host>"],
  into: IO.stream(:stdio, :line), stderr_to_stdout: true
)
```

This invokes `/root/bundles/moonlight/current/bin/moonlight pair <host>`; replace
`<host>` with the Sunshine/GeForce host name or address, then enter the reported
PIN there. The external executable is an exception to the ordinary API-first SSH
workflow. It does not establish that streaming works on the handheld; Moonlight
remains **Untested**. Continue with [Configure Moonlight](moonlight.md).

## Success

Success is task-specific and explicit: IEx returns the documented value, logs
arrive, an install returns successfully and updates `current`, an unmount returns
`:ok`, or the pairing command prints a PIN and the host accepts it. For callable
contracts, follow the module/function reference instead of relying on examples
alone.

## Troubleshooting and safety

- **Connection drops on sleep:** expected; low-power mode takes WiFi down. Wake
  the device and reconnect. Disable only automatic idle sleep from System when
  doing extended work.
- **`nerves.local` reaches the wrong device:** use the unique hostname or address.
- **No WiFi after changing credentials:** return to a known saved network; if the
  initial firmware has no usable network, reflash. See [WiFi](wifi.md).
- **Do not expose SSH or the unauthenticated web UI to an untrusted LAN.** The
  authorized key protects SSH, but the upload/control web endpoints have no auth.
- **Do not remove a mounted card or pull power during writes.** Use orderly
  poweroff and keep backups.

API starting points: `MayonnaiOS.Bundle`, `MayonnaiOS.Cores`,
`MayonnaiOS.Library`, `MayonnaiOS.GamesCard`, `MayonnaiOS.Controller`,
`MayonnaiOS.Pairing`, and `MayonnaiOS.Moonlight`.

[Edit this page](https://github.com/kek/mayonnaios/edit/trunk/docs/ssh-and-iex.md) ·
[Report a documentation issue](https://github.com/kek/mayonnaios/issues/new)
