> **Documentation for current `trunk`; installed firmware may differ.**

# Bluetooth internals

**Status:** controller mode is **Experimental** because an unexplained
intermittent `hci0` bring-up failure remains; its one-shot recovery is verified.
LE scanning and bond management are **Verified**. Outbound pairing and Bluetooth
audio are **Unsupported**.

This page explains the shared stack. For device procedures, use
[Bluetooth controller](bluetooth-controller.md) or
[Bluetooth devices](bluetooth-devices.md).

## Prerequisites

- For source study, understand BLE HCI, L2CAP, ATT/GATT, HID over GATT, and SMP.
- For live diagnosis, connect through [SSH and IEx](ssh-and-iex.md).
- Run only one Bluetooth app at a time; each owns the raw HCI user channel.

## Raw-HCI stack and ownership

There is no BlueZ on the image, and the controller feature added no Buildroot
package or kernel option. The kernel configuration has `# CONFIG_BT_LE is not
set`, so BlueZ over kernel L2CAP would require a board-support rebuild. Instead,
`MayonnaiOS.Bluetooth.HCISocket` opens the raw HCI user channel, which switches
the kernel stack off for that controller and hands HCI to userspace. The
RTL8821CS is a Bluetooth 5.0 dual-mode part and can speak LE directly regardless
of the absent kernel upper layer.

About 4,700 lines of Elixir under `lib/mayonnaios/bluetooth/` implement the HCI
codec, fixed LE L2CAP channels, ATT/GATT server, HID profile, advertising,
scanning, bond storage, and legacy SMP pairing. Everything above the socket is
pure binary/protocol logic. Host tests include the Core specification's `c1` and
`s1` pairing samples so their byte order is checked without hardware.

While controller mode or scanning is active, diagnostics can report `:eusers`.
That means `hci0` is in use, not broken. The apps are supervised `:one_for_all`:
a dead socket invalidates every connection or scan state, so the whole session
stops/restarts together and releases ownership together.

## Borrowed Xbox identity

Controller mode advertises Microsoft's vendor/product identity, the name
`Xbox Wireless Controller`, and the real controller's 283-byte HID descriptor.
This is deliberate: hosts and SDL databases keyed by those identifiers recognize
a gamepad, supply Xbox glyphs, and avoid a mapping step. The descriptor must be
byte-exact because some host drivers trust the claimed identity instead of
parsing arbitrary layouts; `MayonnaiOS.Controller.Report` and its capture-pinned
test own that invariant.

The cost is explicit. The handheld claims an identity it does not own, promises
controls that remain inert (right stick, stick clicks, Share, and direct Xbox
button), and silently accepts rumble despite having no motor. A future host that
probes Microsoft's accessory protocol could expose the seam. Select+Start is
synthesized as Xbox; one brief View/Menu edge may appear while the chord forms.
The report code uses a latch to prevent the release edge leaking as well; delaying
the first press with a timer would add latency to ordinary View/Menu use.

## Pairing and security

Pairing uses legacy BLE *Just Works*: no passkey and no confirmation. It protects
later links with stored keys but does not protect against an active attacker at
the moment of pairing. LE Secure Connections is not implemented; a central in
Secure-Connections-Only mode can reject pairing. `MayonnaiOS.Bluetooth.SMP`
describes what the initiator and Secure Connections work would require.

Bonds are fsynced at `/root/bluetooth/bonds.bin`. Removing one side only leaves
the other trying a stale key, so re-pairing always means forgetting on the host
and clearing the handheld bond.

## Intermittent missing `hci0` and recovery

The RTL8821CS Bluetooth side is UART-attached. The kernel's `hci_uart_h5` driver
binds a serdev child under `serial@5000400`; that bind normally creates `hci0`
about eleven seconds into boot. On one recorded 2026-08-25 boot, the driver was
bound but `/sys/class/bluetooth` was empty and the boot log contained no RTL
probe error. The cause remains unknown.

`MayonnaiOS.Bluetooth.Host` responds to `:enodev` by asking
`MayonnaiOS.Bluetooth.Serdev.revive/0` to unbind/rebind once and then reopening
the socket. This recovery has been verified and is shared by both apps. If the
panel still reports the failure, an advanced user can run:

```elixir
MayonnaiOS.Bluetooth.Serdev.revive()
```

**Success:** `:ok` followed by a successful app start, or a non-`:stopped` value
from `MayonnaiOS.Controller.status/0` or `MayonnaiOS.Pairing.status/0`. Do
not loop the call: one explicit recovery is useful; silent retries can drain the
battery without explaining the fault.

## Unsupported roles and profiles

The scanner already finds candidates, but outbound pairing needs SMP initiator
behavior and a GATT client; current code is responder/server-oriented. Audio then
needs BR/EDR commands and transport, connection-oriented L2CAP, SDP, AVDTP, SBC,
and a route from game audio. None is present. Receiving an external gamepad would
also need a HID host and a kernel-visible input device for RetroArch.

These are future protocol/profile projects, not hidden options. Their user-facing
status remains **Unsupported** until implemented and observed on RG40XXV hardware.

## Troubleshooting source changes

- A host sees the name but wrong buttons: run the descriptor/report tests and
  compare the captured layout before changing identifiers.
- A connection stops at connected or paired: inspect encryption, report-map read,
  and subscription state via `MayonnaiOS.Controller.status/0`.
- `:eusers`: stop the other Bluetooth app. `:enodev`: use the one-shot recovery.
- A host reconnects but input is dead after descriptor/security changes: clear
  both bond stores and pair again.

Reference modules: `MayonnaiOS.Bluetooth.Host`,
`MayonnaiOS.Bluetooth.HCISocket`, `MayonnaiOS.Bluetooth.Peripheral`,
`MayonnaiOS.Bluetooth.GATT`, `MayonnaiOS.Bluetooth.SMP`, and
`MayonnaiOS.Controller.Report`.

[Edit this page](https://github.com/kek/mayonnaios/edit/trunk/docs/bluetooth-internals.md) ·
[Report a documentation issue](https://github.com/kek/mayonnaios/issues/new)
