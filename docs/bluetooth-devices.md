> **Documentation for current `trunk`; installed firmware may differ.**

# Inspect nearby Bluetooth devices and forget bonds

**Status: Verified** for active Bluetooth Low Energy scanning and saved-bond
management on the RG40XXV. Outbound pairing and Bluetooth audio are
**Unsupported**.

## Prerequisites

- MayonnaiOS is at the launcher.
- Leave **Bluetooth controller** first. Both apps require exclusive access to
  `hci0`.
- To remove a controller bond cleanly, be prepared to forget the handheld on
  the host too.

## Scan and manage bonds

1. Open **System → Bluetooth devices**. The upper list shows active LE scan
   results, names, signal strength, and age. It is informational only.
2. Saved hosts from controller mode appear in the bond list. Use D-pad up/down
   to select one.
3. Press **A twice** to forget it. Moving after the first press disarms the
   confirmation.
4. Forget `Xbox Wireless Controller` in the other host's Bluetooth settings as
   well before pairing it again.
5. Press **Menu** to leave and release `hci0`.

## Success

Nearby LE advertisers update on the panel, and a forgotten bond disappears from
the bond list. `MayonnaiOS.Pairing.status/0` returns the same scan, device,
and bond state for advanced diagnosis.

## Unsupported behavior

There is deliberately no Connect action for nearby rows. MayonnaiOS does not
initiate pairing. Headphone audio would require the absent BR/EDR transport,
A2DP profile, codec, and audio-routing stack; scanning a headset does not mean
it can be connected. See [Bluetooth internals](bluetooth-internals.md) for the
boundary and future work.

## Troubleshooting

- **App says Bluetooth is in use:** leave [controller mode](bluetooth-controller.md)
  or stop it with `MayonnaiOS.Controller.stop/0`, then reopen this app.
- **`hci0` is missing:** startup performs one verified serdev rebind. If that
  still fails, see the diagnostics and manual recovery in
  [Bluetooth internals](bluetooth-internals.md).
- **A forgotten host reconnects but cannot encrypt:** remove the saved device on
  the host too; bond removal is two-sided.
- **Nothing nearby appears:** confirm the device is advertising over LE. Classic
  inquiry is not implemented.

API reference: `MayonnaiOS.Pairing`, `MayonnaiOS.Pairing.Cursor`, and
`MayonnaiOS.Bluetooth.Scanner`. Advanced console access is in
[SSH and IEx](ssh-and-iex.md).

[Edit this page](https://github.com/kek/mayonnaios/edit/trunk/docs/bluetooth-devices.md) ·
[Report a documentation issue](https://github.com/kek/mayonnaios/issues/new)
