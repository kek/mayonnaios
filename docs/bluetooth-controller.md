# The Bluetooth controller, in depth

How the handheld presents itself as an Xbox Wireless Controller, what that
choice costs, and how the stack under it works. The README has the short
version: how to pair, what the host receives, and the re-pairing rule.

## The identity is borrowed, and that is the point

The device advertises Microsoft's vendor and product numbers, the real pad's
name, and that pad's HID descriptor byte for byte.

An honest identity cannot practically drive a game. SDL matches controllers
against a database keyed by vendor and product numbers; an unlisted device is
a joystick rather than a gamepad, and a game that asks only for gamepads sees
nothing at all — with Steam on macOS unable to bridge the gap, because it has
no virtual controller there to bridge it with. Claiming the identity of the
one pad every host tests against gets all of those code paths for free:
recognised on sight, correct glyphs, no mapping step.
`MayonnaiOS.Controller.Report` has the full account, including why the
borrowed layout must be byte-exact and the test that pins all 283 bytes of it
against a capture from a real pad.

### What claiming the identity costs

The objection to borrowing a real controller's numbers is real: a host with a
driver for the claimed pad stops reading the descriptor and parses reports
against that pad's fixed layout, so any deviation is scrambled buttons the
host is certain are correct. That is an argument against claiming the numbers
while shipping your own layout. It is not an argument against shipping the
layout too, which is what this firmware does — the drivers' fixed belief is a
correct belief, and the test suite holds the descriptor byte-for-byte against
a capture from a real pad, so a drift is a failing test rather than a
scrambled A button.

What is genuinely given up: the device says it is something it is not, to
hosts and to anyone reading a Bluetooth device list, and controls it does not
have — the right stick, rumble — are promised and permanently inert. A host
that someday probes deeper than any known host does, say for firmware
versions over Microsoft's accessory protocol, will find the seams; nothing on
macOS, SteamOS, Windows or a phone does that today. The trade is written down
here rather than left implicit, because it was made on purpose and the thing
bought with it is a pad every host recognises with no mapping step.

## Reading the panel

The panel shows how far along a connection is, because the four stages all
look identical from the other machine — a controller that does nothing:

    Advertising            on the air, nobody has connected
    Host connected         a host is talking to us, still in the clear
    Paired and encrypted   the HID service is readable
    Reports subscribed     the host is receiving button presses

If it stops at *connected*, the pairing was not finished on the host. If it
stops at *paired*, the host has not decided the device is a gamepad.

A host reads the report map once per pairing and then caches it, so the
*Report map read* row is also how you tell that a firmware whose buttons
moved is being read as the new layout rather than a cached one.

## What the host receives

The left stick, the D-pad as a hat switch, A/B/X/Y by their printed labels,
LB and RB from L1 and R1, the triggers fully pulled or fully released from L2
and R2 — they are switches on this shell — and View and Menu from Select and
Start.

**Select and Start held together are the Xbox button**, which on a Steam Deck
is the Steam button. The first half pressed leaks one brief View or Menu
press while the chord forms; `MayonnaiOS.Controller.Report` has the account
of why that beats a timer, and of the latch that keeps the release edge from
leaking too.

The right stick, the stick clicks, the Share button and the Xbox button are
declared because the real pad declares them, and they rest untouched forever.
Rumble is accepted from the host and dropped, because there is no motor and a
refused write reads as a fault where a silent one reads as a dead motor.

## Pairing security

Pairing is *Just Works*: no passkey, no confirmation, exactly like every
commercial BLE gamepad. That means no protection against someone active on
the air at the moment of pairing. It is written down here rather than left
implicit, because it is a real property of the device and the reason it is
acceptable is that the link carries button presses.

Once paired the keys are kept, so the next connection needs nothing. To undo
it, forget the device on the host **and** clear the keys here:

    iex> MayonnaiOS.Controller.unpair()

Doing only one of the two leaves a host that reconnects, cannot decrypt, and
reports a broken device.

What is deliberately not implemented is LE Secure Connections; a central that
asks for it is answered with a pairing response that does not offer it, and
every host tested falls back to legacy pairing. A host in Secure Connections
Only mode would answer `Pairing Failed 0x03` instead, and
`MayonnaiOS.Bluetooth.SMP`'s moduledoc says what adding it would take.

## From IEx

    iex> MayonnaiOS.Controller.start()
    iex> MayonnaiOS.Controller.status()
    %{advertising: true, connected: false, encrypted: false, subscribed: false,
      name: "Xbox Wireless Controller", address: "...", sent: 0,
      dropped: %{disconnected: 0, unencrypted: 0, unsubscribed: 0, no_credits: 0},
      ...}
    iex> MayonnaiOS.Controller.stop()

`sent` climbing while buttons are pressed is the proof that reports are going
out. The `dropped` counters say why they are not: `unsubscribed` for the
first second of every connection is normal, `no_credits` is not.

## There is no BlueZ on this device, and none was added

The whole stack is Elixir, on top of the raw HCI user channel that
`MayonnaiOS.Bluetooth.HCISocket` already used for the diagnostics probe —
L2CAP, ATT, GATT, the HID profile and the pairing, some forty-seven hundred
lines under `lib/mayonnaios/bluetooth/`. Nothing was added to the Buildroot
system and no kernel option was changed.

That is not a stunt. `# CONFIG_BT_LE is not set` in this kernel's config
means the in-kernel Bluetooth stack does no LE at all, so the ordinary route
— BlueZ over the kernel's own L2CAP sockets — would have needed a BSP change
and a full Buildroot rebuild. A user channel switches the kernel stack off
for that controller anyway and hands over raw HCI, so what the kernel can and
cannot do above HCI stops mattering: the controller is a Bluetooth 5.0
dual-mode part and speaks LE perfectly well when asked directly.

Everything above the socket is a pure function over binaries and is tested on
a laptop, including the pairing arithmetic — `c1` and `s1` are checked
against the sample data in the Core specification, which is the only way to
know the byte order is right. `mix test` covers it with no hardware.

While the app runs it holds hci0, so `MayonnaiOS.Diagnostics.probe_bluetooth/0`
answers `:eusers` until it is stopped. That is the same device being used for
something, not a fault.

## When hci0 is not there at all

`:enodev` is a fault, and an intermittent one. The Bluetooth half of the
RTL8821CS is UART-attached, so the kernel binds `hci_uart_h5` to a serdev
child of `serial@5000400` and that bind is what produces hci0, eleven seconds
into an ordinary boot. Once, on 2026-08-25, it did not: the driver was bound,
`/sys/class/bluetooth` was empty, and `dmesg` for the whole boot carried not
one RTL line — no probe error, no timeout, nothing to read. Both Bluetooth
apps then fail to start with `:enodev`, which from the couch is a menu entry
that does nothing.

Rebinding the driver fixes it, and `MayonnaiOS.Bluetooth.Host` does that once
before reporting `:enodev`, so the device recovers without a reboot and
without SSH. `MayonnaiOS.Bluetooth.Serdev` has the account. By hand it is:

```elixir
iex> MayonnaiOS.Bluetooth.Serdev.revive()
:ok
```

Why the bring-up occasionally no-ops in silence is not understood. The
recovery is verified; the cause is still open.

## Not done yet

**Initiating a pairing.** The Bluetooth devices app finds what is nearby and
manages the bonds this device already has — but every one of those bonds was
made by a host pairing *to* the handheld. Pairing outward, this device
choosing something and bonding with it, is the central role and is not here.

Below the roles, nothing has to change: `Bluetooth.Host`, the HCI codec,
L2CAP framing and the pairing arithmetic are all role-independent, and the
scan that would find the device to pair with already runs. What is missing is
the half of each protocol that faces the other way —
`MayonnaiOS.Bluetooth.SMP` answers a pairing today and would need the
initiator half of one, and `MayonnaiOS.Bluetooth.GATT` is a server where a
central needs a client.

**The profiles after it**, which are the expensive part, because a bonded
device does nothing until there is a profile to use it with. Audio means
A2DP: SDP, AVDTP and an SBC encoder over a BR/EDR transport this firmware
does not have, and then a way to route a game's audio into the stream, which
means another package in the image and therefore a system rebuild. A paired
gamepad means a HID host and then some way to present it to Linux as an input
device, since RetroArch reads evdev and nothing in this VM can hand it a
device node without the kernel's help.

Worth deciding one at a time whether each is worth having. The app is built
so that adding one is a profile under `MayonnaiOS.Bluetooth` and a row action
in `MayonnaiOS.Scene.Pairing`, and nothing else has to move.
