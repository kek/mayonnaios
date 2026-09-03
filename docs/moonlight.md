> **Documentation for current `trunk`; installed firmware may differ.**

# Configure game streaming with Moonlight

**Status: Untested.** Bundle installation and configuration editing have host-side
tests, but Moonlight has not been run on the RG40XXV. This page does not claim a
successful handheld stream.

## Prerequisites

- The RG40XXV and a Sunshine or compatible GeForce host are on the same network.
- WiFi-first SSH access works; pairing is the one required SSH step.
- The Moonlight bundle from
  [`mayonnaios_bundles`](https://github.com/kek/mayonnaios_bundles) is available.

## Install the bundle

Connect as described in [SSH and IEx](ssh-and-iex.md), then run:

```elixir
MayonnaiOS.Bundle.install(MayonnaiOS.Bundle.spec(:moonlight))
```

The **Moonlight** launcher row remains visible but unlaunchable until the binary
exists. The settings row is usable before installation so configuration can be
prepared first.

## Configure from the panel

1. Open **System → Moonlight settings**.
2. Use up/down to select host address, resolution, frame rate, bitrate, codec,
   app, or **Save**.
3. Use left/right to cycle choice rows. Press **A** to edit the address or app;
   in the character picker, left/right move, up/down change, **Y** removes, and
   **A** accepts the text.
4. Review the header. It says **unsaved changes** whenever panel state differs
   from the saved file.
5. Select **Save** and press **A**. Leaving with Menu before this discards edits.

The first load uses the installed bundle's template when available, otherwise
matching defaults: 1280×720 (720p), 30 fps, 5000 kbps, H.264, SDL platform, and
Moonlight's default app. The screen edits
`/root/.config/moonlight/moonlight.conf`; it preserves comments, blank lines,
and unknown keys such as `surround`, `rotate`, `viewonly`, and `packetsize`.
Hand-written choice values are retained rather than snapped to a menu value.

**Success:** the panel reports `Saved to
/root/.config/moonlight/moonlight.conf`. A saved change applies when the next
stream starts, not to a stream already running. This confirms only that the
configuration was written.

## Pair over SSH

Pairing cannot be completed on the panel because Moonlight prints a PIN that must
be entered at the host. At the SSH IEx prompt, run the same bundle command through
`System.cmd/3` so its output remains visible:

```elixir
System.cmd(
  "/root/bundles/moonlight/current/bin/moonlight",
  ["pair", "<host>"],
  into: IO.stream(:stdio, :line), stderr_to_stdout: true
)
```

This invokes `/root/bundles/moonlight/current/bin/moonlight pair <host>`; replace
`<host>` with the host name or address. Enter the displayed PIN in the host UI
and retain the resulting client state.
This is separate from editing `moonlight.conf`; the settings screen intentionally
does not infer pairing from a local certificate.

## Try a stream without overstating support

After installation, configuration, and pairing, select **Moonlight** in the
launcher. The configured command is `moonlight stream -config
/root/.config/moonlight/moonlight.conf`. Treat rendering, software decoding,
audio, controls, latency, and stability as unanswered RG40XXV checks until an
observed run updates the status page.

## Troubleshooting

- **Moonlight row is grey:** install the bundle and verify
  `MayonnaiOS.Moonlight.installed?/0`.
- **Save fails:** the panel names the target and reason (for example read-only or
  full storage). Free space or repair the writable filesystem, then save again.
- **An SSH-only key disappeared:** it should be preserved; inspect
  `MayonnaiOS.Moonlight.render/2` behavior and report the original file.
- **Settings seem ignored:** stop and start a new stream; Moonlight reads the file
  only at startup.
- **Pairing or stream fails:** consult the bundle repository and record this as
  hardware verification, not as proof that host config tests failed.

API reference: `MayonnaiOS.Moonlight`, `MayonnaiOS.Moonlight.App`, and
`MayonnaiOS.Bundle`. See [hardware status](hardware-status.md).

[Edit this page](https://github.com/kek/mayonnaios/edit/trunk/docs/moonlight.md) ·
[Report a documentation issue](https://github.com/kek/mayonnaios/issues/new)
