# RG SP MayonnaiOS port plan

**Goal:** Run MayonnaiOS on the **Anbernic RG SP** with the same core experience as on RG40XXV. This is a plan, not a claim that MayonnaiOS has been tested on RG SP. Preserve the stock card; flash only a separately authorized spare card.

## Starting point

[`kek/nerves_system_rgsp`](https://github.com/kek/nerves_system_rgsp) has booted a temporary Nerves application on physical RG SP hardware. Its 720×480 panel displayed logos and a console; `/root` mounted, firmware validated, Wi-Fi SSH worked, and USB ECM SSH worked on one connection. The BSP has Cairo, FreeType, Mesa/Panfrost, ALSA and bring-up tools configured. That does **not** establish that the MayonnaiOS UI, input, audio, GPU applications, storage, or updates work on this device. See the [BSP README](https://github.com/kek/nerves_system_rgsp/blob/main/README.md) for hardware evidence and limitations.

## 1. Make RG SP a first-class application target

- [x] Add `:rgsp` to the target list and a path dependency on `../nerves_system_rgsp` in `mix.exs`, without changing the RG40XXV target.
- [ ] Add `config/rgsp.exs` with a complete `MayonnaiOS.Device` profile. Establish the actual input names and button codes before fixing mappings: the SP has a lid switch and does not inherit the RG40XXV's analog joystick. Account for app paths that currently expect a stick or two independently controllable LEDs rather than supplying fictional device names.
- [x] Make the target Scenic viewport **720×480** instead of the 640×480 hard-coded in `config/target.exs`; verify framebuffer format, stride, and cairo-fb output on the device. Keep the host and RG40XXV viewports at their intended sizes.
- [x] Add targeted profile/config tests and update RG SP build instructions after a successful firmware build. Provide the existing SSH/Wi-Fi provisioning required to retain access.

**Exit:** `MIX_TARGET=rgsp mix firmware` builds against this BSP and boots MayonnaiOS to a visible, navigable UI on an authorized spare card.

## 2. Verify the inputs and user-facing peripherals

- [ ] Use `evtest` on the physical device to record D-pad, action, shoulder, menu, volume, power and lid close/open events. Check the resulting MayonnaiOS semantic bindings and button chords, including sleep and orderly poweroff.
- [ ] Confirm speaker, headphones, jack detection, mixer controls and actual volume changes with `aplay`/`amixer`. An ALSA device appearing is not proof that playback works; verify the route is usable at volume zero as well as above it.
- [ ] Inventory LEDs, power-supply names and readings, backlight path/behavior, and RTC presence; reflect observed capabilities in the device profile. Test lid/backlight wake and recovery on the hardware. MayonnaiOS sleep on RG40XXV is not suspend-to-RAM; do not promise deep suspend on SP without separate evidence.
- [ ] Check the second SD slot's block-device identity, insert/remove, filesystem mounting and safe unmount. Avoid assuming that the RG40XXV's `/dev/mmcblk2p1` has been verified on SP.

**Exit:** Input, audio, lid/backlight, power indicators and removable storage perform their documented MayonnaiOS actions on RG SP.

## 3. Exercise rendering, games and native bundles

- [ ] Test the actual cairo-fb Scenic UI and DRM-master handoff to a native program. Displayed kernel logos alone do not cover either path.
- [ ] Exercise Panfrost/Mesa userspace rendering (`kmscube`), RetroArch, representative cores and saves on RG SP; test Moonlight separately if it is to be advertised as supported.
- [ ] Check that published `mayonnaios_bundles` artifacts built against the RG40XXV staging sysroot have compatible ABI/runtime libraries in this BSP. If not, build, publish and checksum SP-compatible artifacts in the bundles repository, then select them in this application's catalogue. Do not bypass bundle checksum verification.

**Exit:** A game can be launched, displayed, controlled, heard and saved, and the launcher returns cleanly.

## 4. Harden storage, boot and firmware updates

- [ ] Test sustained DRAM and SD-card activity. The BSP's first F2FS format completed but emitted MMC erase timeouts; determine whether discard or normal I/O remains affected.
- [ ] Address or positively guard MMC numbering assumptions with two cards inserted. The BSP's `root=/dev/mmcblk0p2` is probe-order-dependent; `MayonnaiOS.BootDiagnostics` **writes raw sectors** of `/dev/mmcblk0`. Keep raw-card diagnostics off until device identity and the reserved layout are proved for this image, or replace the assumption safely.
- [ ] Physically verify clean reboot and poweroff, firmware upload to the inactive A/B slot, validation and rollback/recovery on a spare card. First boot alone is not an OTA test.
- [ ] Investigate observed Wi-Fi `rtw88_8821cs` TX-report/re-association errors and inconsistent USB ECM host enumeration; retain at least one verified access/recovery route for tests. Test Bluetooth separately before claiming controller support.

**Exit:** Storage and network survive repeated normal use; a tested update/rollback path does not depend on a fragile device-number guess.

## 5. Record evidence and scope accurately

- [ ] Add an RG SP capability matrix with verified/experimental/untested distinctions, device observations and firmware revision. Do not relabel RG40XXV observations as SP evidence.
- [ ] Update build/flash instructions and system/bundles ownership links. Correct stale bring-up comments and changelog claims in the BSP as separate, evidence-backed work.

**Minimum end-to-end milestone:** A MayonnaiOS image built for `:rgsp` boots from a spare card, displays a correctly sized UI, navigates via physical controls, plays audio and one game, remains reachable over Wi-Fi, responds appropriately to lid/power input, and completes an A/B OTA test. GPU, Bluetooth, HDMI, Moonlight and deep-suspend support are **not** implied by that milestone.
