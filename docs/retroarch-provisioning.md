> **Documentation for current `trunk`; installed firmware may differ.**

# Historical decision: provision RetroArch as a bundle

**Historical decision record — recorded 2026-08-16 from repository and RG40XXV
observations.** The still-current decision is authoritative: RetroArch is built
and released by
[`mayonnaios_bundles`](https://github.com/kek/mayonnaios_bundles), then installed
as a versioned, checksum-verified bundle on the writable partition. It is **not**
a Buildroot package and does not belong in `nerves_system_rg40xxv`.

The Buildroot package under
[`docs/retroarch-reference/`](https://github.com/kek/mayonnaios/tree/trunk/docs/retroarch-reference)
is repository-only evidence from the investigation. It has **never been built**.
Its comments are suspect and must not be treated as verified facts or current
build instructions. For maintained behavior, read [RetroArch internals](retroarch-internals.md);
for repository ownership, read [Repository responsibilities](repositories.md).

## Decision drivers

Two reasons led to the bundle decision, and scope is decisive.

**Scope.** `nerves_system_rg40xxv` is board support: kernel, device tree,
bootloader, drivers, and base userland. An emulator is product content. Another
product using the board should not inherit RetroArch, and a core update should
not require reflashing firmware.

**Size.** Firmware uses two rootfs slots, each written whole during an update.
RetroArch plus cores is on the order of 100 MB. Baking it into the image would
duplicate it across both slots and turn each content update into a firmware
write, while the writable application partition has substantially more room.

The investigation also found a mechanical constraint at that time: Nerves
invoked Buildroot with the system repository as its one `BR2_EXTERNAL` tree, and
the Docker build runner exposed the system paths but not an arbitrary sibling
package tree. A Buildroot package would therefore have had to live in the system
repository, reinforcing the ownership mismatch. This paragraph records the
investigation; consult current Nerves and system-repository source before relying
on those implementation details today.

## Chosen architecture

```text
mayonnaios_bundles -> versioned native archive/release
                                |
                                v
mayonnaios          -> fetch, verify, install on writable storage
                                |
                                v
launcher            -> execute the selected current bundle
```

The responsibilities are:

1. **Native build repository.** Cross-build RetroArch and cores for the system's
   `aarch64-nerves-linux-gnu` sysroot and publish versioned archives.
2. **This application.** Keep trusted SHA-256 values in firmware, download only
   on request, verify before unpacking, install to versioned writable paths, and
   select the `current` version.
3. **Launcher/runtime.** Re-stat program availability so an installed bundle can
   become launchable without rebuilding firmware.

Current archive formats, versions, and release procedures belong to
`mayonnaios_bundles`; this record does not freeze the pre-decision sketch.

## Evidence supporting writable installation

The decision record contains an RG40XXV observation that `/root` was an f2fs
writable partition mounted `nodev` but not `noexec`; an executable script ran
there. `/data` resolved to the same partition. The recorded sample had a full
66.5 MB read-only rootfs and approximately 13.4 GB free under `/root`.

Those observations answered the load-bearing question—optional native content
could execute from writable storage—and made a dedicated content partition
unnecessary. They are historical evidence, not a current capacity guarantee;
inspect the device when exact free space matters.

## Never-built Buildroot investigation

The retained reference package captured a possible KMS/DRM, no-X11,
no-Wayland, GLES configuration before the bundle decision. An adversarial source
review found several comments that were asserted as observations but false or
incomplete, including claims about `EGL_NO_X11`, a nonexistent assets submodule,
the effect of `--disable-neon`, and an ungated fontconfig probe.

The configure flags were not thereby proven wrong, but neither the package nor
its claims were validated by a build. Treat the files only as leads when
researching upstream flags. Verify every claim against the selected RetroArch
source and the current bundle pipeline; do not copy their comments into current
documentation as facts.

## Current decision check

The decision remains in force while optional native programs are built in
`mayonnaios_bundles`, catalogue checksums are owned by this application, and
installation targets writable versioned directories. Revisit it only if those
ownership or platform constraints change, and record new evidence in a new
decision rather than silently rewriting this historical investigation.

[Edit this page](https://github.com/kek/mayonnaios/edit/trunk/docs/retroarch-provisioning.md) ·
[Report a documentation issue](https://github.com/kek/mayonnaios/issues/new)
