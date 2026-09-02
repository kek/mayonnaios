> **Documentation for current `trunk`; installed firmware may differ.**

# Repository responsibilities

MayonnaiOS spans three repositories. Put a change where its artifact and
maintenance contract are owned; do not copy another repository's build procedure
here.

| Repository | Owns | Put changes here when… | Does not own |
|---|---|---|---|
| [`kek/mayonnaios`](https://github.com/kek/mayonnaios) | This OTP application: launcher and device tools, Elixir behavior, target/application configuration, firmware assembly, bundle/core catalogue metadata, and these docs. | changing a scene, task flow, application service, Pickles runtime, firmware config, user guide, or hardware-status claim | Linux, U-Boot, device tree, Buildroot packages, or cross-building native applications |
| [`kek/nerves_system_rg40xxv`](https://github.com/kek/nerves_system_rg40xxv) | RG40XXV board support: Nerves system, Buildroot configuration/base userland, Linux kernel and drivers, device tree, U-Boot, fwup layout, and exported target sysroot. | changing boot, partitions, kernel/device-tree hardware support, system libraries, or packages every application on the board should inherit | MayonnaiOS UI/application policy or optional emulator/streaming content |
| [`kek/mayonnaios_bundles`](https://github.com/kek/mayonnaios_bundles) | Cross-build and release pipelines for native optional content such as RetroArch, libretro cores, and Moonlight, built against the RG40XXV system sysroot. | changing native source versions, patches, compile flags, bundle layout, or published bundle/core artifacts | installing/selecting those artifacts in the MayonnaiOS application, or the BSP itself |

## How the repositories connect

1. `nerves_system_rg40xxv` produces the bootable system and sysroot.
2. This repository consumes that system as the sibling path dependency
   `../nerves_system_rg40xxv` when `MIX_TARGET=rg40xxv` and produces MayonnaiOS
   firmware.
3. `mayonnaios_bundles` builds optional native programs against the matching
   sysroot and publishes versioned archives.
4. This application's bundle/core catalogue supplies release URLs and trusted
   SHA-256 values; the device downloads, verifies, and installs those archives
   onto writable storage.

A native program is not automatically a system package. RetroArch remains
optional product content installed as a bundle rather than becoming part of the
read-only firmware. The rationale and never-built alternative are preserved in
the [Historical RetroArch provisioning decision](retroarch-provisioning.md);
current device behavior is in [RetroArch internals](retroarch-internals.md).

## Choose the owner before editing

- A new or corrected Elixir behavior, owner task, or firmware catalogue entry:
  start in **mayonnaios**.
- A missing kernel option, device-tree node, bootloader behavior, base library,
  or partition rule: start in **nerves_system_rg40xxv**.
- A RetroArch/core/Moonlight patch or cross-build/release change: start in
  **mayonnaios_bundles**.
- A change crossing boundaries: make separately reviewable changes in each
  owner and link them. Keep detailed build and release instructions in that
  repository, where its CI can validate them.

**Success:** the repository that produces the changed artifact owns its source,
tests, and procedure, while this site links outward for external build details
instead of presenting a stale duplicate.

For firmware assembly after the required system is available, see
[Build and flash firmware](build-and-flash.md). For local application work, see
[Develop on the host](development.md).

[Edit this page](https://github.com/kek/mayonnaios/edit/trunk/docs/repositories.md) ·
[Report a documentation issue](https://github.com/kek/mayonnaios/issues/new)
