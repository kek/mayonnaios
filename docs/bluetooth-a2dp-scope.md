> **Documentation for current `trunk`; installed firmware may differ.**

# Scope estimate: Bluetooth headphone audio (A2DP)

**Status: Unsupported.** Nothing described here is implemented. This page
estimates what implementing it would cost and records the measurements that
should decide whether to start. Sizes are **Estimated** unless marked
**Measured**. For the current boundary, read
[Bluetooth internals](bluetooth-internals.md); for what the device does today,
read [Bluetooth devices](bluetooth-devices.md).

Connecting headphones means acting as an A2DP **source**: the handheld
initiates on BR/EDR, so it needs the initiator role, the classic transport, a
media profile, an encoder, and a route from game audio. The existing stack is
an LE responder and supplies none of those five.

## What the existing stack contributes

- `MayonnaiOS.Bluetooth.HCISocket` is unchanged. BR/EDR rides the same raw HCI
  user channel, and the `# CONFIG_BT_LE is not set` caveat in
  [Bluetooth internals](bluetooth-internals.md) does not apply to it. **No
  board-support rebuild is required for the Bluetooth side.**
- `MayonnaiOS.Bluetooth.Host`, `MayonnaiOS.Bluetooth.Serdev`, and the
  `:one_for_all` ownership rule carry over as-is.
- `MayonnaiOS.Bluetooth.L2CAP` fragmentation and reassembly is transport
  neutral and already tested against short fragments, early continuations, and
  overlong length fields.
- `MayonnaiOS.Bluetooth.Bonds` keeps its fsynced store shape. BR/EDR link keys
  replace LTKs; the record layout does not change.
- `MayonnaiOS.Bluetooth.HCI` keeps its command and event codec structure. Every
  opcode currently in it is LE.

## What has to be built

| Layer | Estimated lines | Notes |
| --- | --- | --- |
| BR/EDR link control | 800–1200 | Inquiry, Create Connection, Read Remote Supported Features, packet-type selection, role switch, link supervision |
| Secure Simple Pairing | included above | IO Capability Request/Response, User Confirmation, Link Key Notification. The controller performs the cryptography, so this is HCI exchange rather than the hand-rolled arithmetic in `MayonnaiOS.Bluetooth.SMP` |
| Connection-oriented L2CAP | 400–600 | `MayonnaiOS.Bluetooth.L2CAP` knows three fixed LE CIDs. Dynamic channels need Connection and Configuration Request/Response, MTU negotiation, an automatic flush timeout, and per-CID demultiplexing |
| SDP client | 300–500 | Service discovery on PSM `0x0001` to find the sink's AVDTP PSM and supported features |
| AVDTP | 800–1000 | Signalling on PSM `0x0019`: Discover, Get Capabilities, Set Configuration, Open, Start, Suspend, Close, Abort, plus the stream state machine and an RTP-framed media channel |
| SBC encoder | C NIF or port | Mandatory codec. Not viable in pure Elixir at 48 kHz stereo on this SoC |
| AVRCP | 400+ | Optional. Without it the headphone's transport buttons and absolute volume do nothing |

That is roughly 2,500–4,000 lines of Elixir plus a native encoder, comparable
in size to the existing LE stack. The specification surface is wider, but
BR/EDR pairing is materially cheaper than SMP was.

## Three constraints decide the feature

### Audio has no route out of the players

RetroArch and Moonlight open `hw:0,0` directly, and nothing in the image mixes;
see `MayonnaiOS.Audio` for how narrow that path is. Three options exist:

- An `/etc/asound.conf` chain writing into a FIFO the BEAM reads. Needs no
  image change and is the cheapest way to prove the idea, but the sample clock
  comes from the slave PCM and the arrangement is fragile.
- `CONFIG_SND_ALOOP` in `nerves_system_rg40xxv`. The conventional answer, at
  the cost of a kernel rebuild in the board-support repository.
- Patching the player's audio driver. Ties MayonnaiOS to a RetroArch build and
  is not worth it.

`MayonnaiOS.Volume` needs a second path either way: it drives RetroArch's
decibel setting and the codec mixer, neither of which remains in the chain once
audio leaves over Bluetooth.

### Latency is inherent, not tunable

A2DP adds 100–200 ms before the headphone's own buffering. That is acceptable
for Moonlight and music and unacceptable for emulators. Decide before writing
code whether shipping "Bluetooth audio, but not for games" is the intended
outcome; no amount of implementation quality removes this.

### Bandwidth shares one UART

SBC joint stereo at 48 kHz and bitpool 53 is roughly 345 kbps of payload
(**Estimated**), before RTP, L2CAP, HCI, and H5 framing and SLIP escaping. All
of it crosses the single UART the kernel drives at the rate
`h5_btrtl_setup()` negotiated, and **that rate is not recorded anywhere in this
repository**. At 1.5 Mbps there is comfortable headroom; at 921600 the link
runs over half duty cycle and jitter becomes the risk.

### Concurrency with controller mode

`MayonnaiOS.Bluetooth.Credits` is per-controller and documents its own
assumption of a single link. Streaming A2DP while advertising as a gamepad
shares both the buffer pool and the UART. Either forbid the combination at
first, as the current apps do for `hci0`, or grow the credit accounting up
before attempting both.

## Measure these three before starting

1. **The H5 baud rate, and the BR/EDR buffer pool.** `read_buffer_size` is
   already implemented and `MayonnaiOS.Bluetooth.Host.read_buffers/0` uses it
   only as a fallback when the LE pool reads as zero. The LE pool is
   **Measured** at eight packets of 27 bytes; the classic pool is unmeasured.
   One IEx session answers both.
2. **A PCM route out of RetroArch.** Capture player audio to a file through
   `asound.conf`. This proves or kills the routing story with no Bluetooth code
   written.
3. **SBC encoder cost on device.** Encode a wav through the candidate NIF and
   compare per-frame time against the frame budget: 128 samples per channel at
   48 kHz is 2.67 ms of audio per frame.

If any of the three fails, the protocol work is wasted.

## Implementation order

1. BR/EDR connect and Secure Simple Pairing against one known headset.
2. Connection-oriented L2CAP.
3. AVDTP signalling with a hardcoded SBC configuration.
4. Media streaming.
5. SDP, replacing the assumed PSM.
6. AVRCP.

Steps 1 through 4 are enough for audible output on most headphones, because a
sink that advertises AVDTP on the standard PSM will accept a fixed SBC
configuration it already supports. Step 5 is what makes it work on the rest.

## Open questions

- Which SBC implementation, and under which license. The BlueZ tree's SBC
  sources are not uniformly licensed with the rest of that project; confirm
  terms before vendoring anything into the image.
- Whether A2DP and controller mode are ever allowed to run together, which
  determines how much the credit accounting has to change.
- Whether the launcher exposes an output-device choice, or Bluetooth audio
  simply captures output whenever a sink is connected.

[Edit this page](https://github.com/kek/mayonnaios/edit/trunk/docs/bluetooth-a2dp-scope.md) ·
[Report a documentation issue](https://github.com/kek/mayonnaios/issues/new)
