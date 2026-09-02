> **Documentation for current `trunk`; installed firmware may differ.**

# RG40XXV hardware status

This matrix is for the **Anbernic RG40XXV handheld** only. It separates source and
test coverage from observations on physical hardware. Unless a row names a
firmware hash, the repository does not contain a dated firmware artifact for that
observation; do not read “current source” as a release guarantee.

## Status legend

- **Verified** — implemented and observed on RG40XXV hardware.
- **Experimental** — implemented and observed, but incomplete, unreliable, or
  carrying unresolved risk.
- **Untested** — implemented, but not yet run on RG40XXV hardware.
- **Unsupported** — not provided.

**Measured** identifies a recorded measurement. **Estimated** identifies a number
that still needs measurement. These evidence qualifiers do not change a feature's
maturity status.

## Capability matrix

| Area | Status | Evidence or firmware reference | Limitation or next step |
|---|---|---|---|
| 640×480 display and GPU | **Verified** | RG40XXV profile fixes the panel at 640×480; current hardware notes record CPU rendering to `/dev/fb0` and Panfrost/Mesa support for native programs. No firmware hash is recorded. | The host's 640×480 window is a development aid, not device evidence. |
| Built-in controls | **Verified** | The RG40XXV profile and current hardware notes identify the gamepad, stick, volume, headphone-jack, and power input devices; focused input and launcher tests cover their mappings. | A new shell or target needs a complete profile and physical verification. |
| Speaker, headphones, and volume | **Verified** | Current hardware notes record audio output, jack switching, and mixer control from the volume rocker. No firmware hash is recorded. | Bluetooth audio is separate and unsupported; see its row below. |
| Battery, charging, and thermal readings | **Verified** | The profile names AXP20x battery/USB supplies; current hardware notes record charge/discharge reporting and four thermal zones. | Values are diagnostics, not a calibrated runtime estimate. |
| WiFi and on-device network settings | **Verified** | Current hardware notes record RTL8821CS WiFi and the settings flow; `MayonnaiOS.WiFi` and focused tests cover scan, additive join, rejected-key rollback, and forget behavior. | WiFi is the only verified remote-access path. An incorrect initial network can require reflashing. |
| USB CDC-ECM gadget (`usb0`) | **Untested** | `MayonnaiOS.USBGadget` implements configfs setup and `config/target.exs` configures `VintageNetDirect`. RG40XXV USB-C cable enumeration has not been observed. | Do not rely on USB for SSH or recovery until host enumeration is verified on hardware. |
| Bluetooth controller | **Experimental** | The controller, Xbox-compatible HID reports, pairing, and one-shot serdev recovery have been observed; source and focused tests cover the stack. No firmware hash is recorded. | `hci0` sometimes fails to appear for an unexplained reason. Recovery is verified, but the cause remains open. |
| Bluetooth LE scan and bond management | **Verified** | The Bluetooth devices app has been observed scanning and managing saved bonds; `MayonnaiOS.Pairing` and scanner/bond tests cover the behavior. | It owns `hci0` while open, so it cannot run with controller mode. |
| Outbound Bluetooth pairing and audio | **Unsupported** | `MayonnaiOS.Pairing` documents that initiator support, BR/EDR transport, A2DP, audio routing, and BlueZ are absent. | Nearby devices can be inspected, but headphones cannot be connected. |
| Internal SD storage | **Verified** | Current hardware notes and storage modules cover the writable internal ROM library, bundles, cores, and durable save handling. | User data still needs backups; orderly poweroff is preferred. |
| Second SD slot | **Verified** | The RG40XXV profile names `/dev/mmcblk2p1`; current hardware notes record mounting and merged reads, and `MayonnaiOS.GamesCard` tests cover mount ownership. | Writes default to internal storage. Unmount the removable card before pulling it. |
| Sleep and backlight wake | **Verified** | Power-button, explicit, and automatic sleep paths are implemented; hardware observation confirms backlight off/on behavior. Focused sleep tests cover wake and timer policy. | This is fake sleep, not suspend-to-RAM. |
| Extra low-power measures | **Experimental**, **Estimated** | On firmware `3cc86f59`, `MayonnaiOS.LowPower` records a **Measured** awake baseline of 415 mA at 3.78 V (1.57 W). Renderer, radio, governor, and CPU actions are implemented; governor and rfkill are currently no-ops. | Total sleep savings have not been measured. The documented 255–315 mA backlight and 150–250 mA full-mode figures are estimates, not results. |
| RetroArch, cores, and saves | **Verified** | Current hardware notes record RetroArch bundle operation, independently installed checksum-verified cores, versioned installs, and save durability; bundle/core/save tests cover the contracts. | RetroArch is not in the firmware image and must be installed as a bundle. Core compatibility depends on artifacts built for this system. |
| Moonlight streaming | **Untested** | Bundle installation and editable configuration are implemented and host-tested in `MayonnaiOS.Moonlight`; the repository explicitly records no handheld run. | Pairing still requires SSH, and decoding/rendering/controls must be verified on RG40XXV before claiming a successful stream. |

## What is and is not a supported hardware target

`rg40xxv` is the only physical product profile documented here. `host` is a
640×480 development profile used for tests and UI work; it cannot verify device
drivers, rendering, radio behavior, or power use. Other names in the Mix target
list are Nerves dependency scaffolding, not supported MayonnaiOS products. They
need a complete device profile and hardware evidence before this matrix can include
them.

## Evidence boundaries

Tests establish Elixir contracts and failure handling, not physical effects. For
hardware-facing changes, update this page with the observed device, status, date,
and firmware hash when those are available. The detailed measurement currently
preserved in source is the `3cc86f59` low-power baseline; no measured saving is
recorded.

[Edit this page](https://github.com/kek/mayonnaios/edit/trunk/docs/hardware-status.md) ·
[Report a documentation issue](https://github.com/kek/mayonnaios/issues/new) ·
[View the RG40XXV profile](https://github.com/kek/mayonnaios/blob/trunk/config/rg40xxv.exs)
