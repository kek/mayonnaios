> **Documentation for current `trunk`; installed firmware may differ.**

# Use the RG40XXV as a Bluetooth controller

**Status: Experimental.** Controller operation and one-shot recovery are verified,
but `hci0` has intermittently failed to appear at boot for an unexplained reason.
That limitation is adjacent to the status because a failed start otherwise looks
like a menu action that did nothing.

## Prerequisites

- MayonnaiOS is running on the Anbernic RG40XXV handheld.
- Leave **Bluetooth devices** first; scanning and controller mode are mutually
  exclusive because each owns `hci0`.
- Open the target host's Bluetooth settings and keep the handheld nearby.

## Pair and use it

1. Open **Apps → Bluetooth controller**. It advertises as
   `Xbox Wireless Controller`.
2. Pair on the host:
   - **Steam Deck:** **Settings → Bluetooth**, then select the controller with
     the gamepad icon.
   - **Windows:** **Settings → Bluetooth & devices → Add device → Bluetooth**.
     It pairs without a code.
   - **macOS:** **System Settings → Bluetooth**, then connect it. Steam and other
     GameController clients receive Xbox-compatible input.
3. Watch the panel progress through **Advertising**, **Host connected**,
   **Paired and encrypted**, and **Reports subscribed**.
4. Use the controls. The host receives the left stick, D-pad, A/B/X/Y by their
   printed labels, LB/RB from L1/R1, digital full-release/full-pull triggers from
   L2/R2, and View/Menu from Select/Start. Hold **Select+Start** for Xbox/Steam.
5. Press **Menu** to leave controller mode and return input to the launcher.

The declared right stick, stick clicks, Share, and direct Xbox button remain
inert; rumble writes are accepted and dropped because the handheld has no motor.

## Success

The panel reaches **Reports subscribed**. While pressing controls,
`MayonnaiOS.Controller.status/0` shows `sent` increasing. A short period of
`dropped.unsubscribed` at connection start is normal; continuing `no_credits`
drops are not.

A host commonly caches the HID report map for the lifetime of a pairing. The
panel's **Report map read** indication confirms that the current descriptor was
read rather than only a cached one.

## Host-specific troubleshooting

- **macOS lists the pad but receives no input:** grant the game or Steam
  **System Settings → Privacy & Security → Input Monitoring**, quit it fully,
  and reopen it. Enumeration needs no permission; input delivery does.
- **Stops at Host connected:** finish pairing on the host. **Stops at Paired:**
  the host has not subscribed to HID reports or recognized it as a gamepad.
- **Firmware changed the descriptor/security and reconnect is broken:** forget
  the device on the host **and** clear the handheld bond with
  `MayonnaiOS.Controller.unpair/0`. Clearing only one side leaves stale keys.
- **Bluetooth is in use / `:eusers`:** leave **Bluetooth devices** or call
  `MayonnaiOS.Pairing.stop/0`, then retry.
- **`hci0` missing / `:enodev`:** startup performs one verified serdev rebind.
  If it still fails, follow the one-shot manual recovery in
  [Bluetooth internals](bluetooth-internals.md). The cause remains unresolved,
  so controller mode remains **Experimental**.

## Security and implementation boundary

Pairing is BLE *Just Works* with no passkey or confirmation. Stored keys secure
later links, but an active attacker at the moment of pairing is not excluded.
The Xbox identity is deliberately borrowed for host compatibility. The identity,
byte-exact descriptor trade-off, raw-HCI/no-BlueZ stack, recovery mechanics, and
unsupported future roles live in [Bluetooth internals](bluetooth-internals.md),
not in this task procedure.

API reference: `MayonnaiOS.Controller` and
`MayonnaiOS.Controller.Report`. Nearby-device and bond management is covered by
[Inspect Bluetooth devices](bluetooth-devices.md); advanced calls are in
[SSH and IEx](ssh-and-iex.md).

[Edit this page](https://github.com/kek/mayonnaios/edit/trunk/docs/bluetooth-controller.md) ·
[Report a documentation issue](https://github.com/kek/mayonnaios/issues/new)
