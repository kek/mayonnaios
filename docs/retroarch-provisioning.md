# Provisioning RetroArch

**Decision:** RetroArch is built by a separate pipeline, published as a
versioned checksummed tarball, and installed onto the device's writable
partition by this application. It is **not** a Buildroot package and does not
go in `nerves_system_rg40xxv`.

## Why not in the system

Two reasons, and the scope one is the one that decides it.

**Scope.** `nerves_system_rg40xxv` is board support: kernel, device tree,
bootloader, drivers, base userland. An emulator is product content. A second
product on the same board should not inherit RetroArch, and a core update
should not mean reflashing an operating system.

**Size.** Firmware here is A/B: two rootfs slots, each written whole on
update. RetroArch plus a handful of cores is on the order of 100 MB. Baking
that into the image doubles it on disk and makes every core update a full
firmware write, on a device whose only reliable link is WiFi.

There is also a mechanical constraint worth writing down, because it is what
makes "just put the package somewhere else" impossible rather than merely
untidy. Nerves invokes Buildroot with exactly one external tree:

    create-build.sh:189
    make -C "$NERVES_SYSTEM/buildroot" BR2_EXTERNAL="$NERVES_SYSTEM" ...

and the Docker build runner bind-mounts exactly two host paths into the
container (`nerves/lib/nerves/artifact/build_runners/docker.ex:351`):
`nerves_system_br` at `/nerves/env/platform`, and the system package itself at
`/nerves/env/<app>`. A br2-external tree living in a sibling repository is not
visible from inside the build at all. So a Buildroot package can only ever
live in the system repo — which is the argument for not making it a Buildroot
package.

## The shape

    build repo  ->  retroarch-<version>-aarch64.tar.xz + .sha256
                        |
                        v
    this app    ->  fetch, verify, unpack to the writable partition
                        |
                        v
    Launcher    ->  runs it like any other program

Three pieces:

1. **A build repo.** Cross-compiles RetroArch and the cores for
   `aarch64-nerves-linux-gnu` in a container, against the same library set the
   system ships (GBM, EGL, GLES, ALSA, libdrm). Publishes a tarball and a
   SHA-256 to a release.
2. **A provisioner in this app.** Downloads on demand, verifies the checksum
   before unpacking, installs under the writable partition, records the
   installed version, and is idempotent.
3. **`ScenicRg40xxv.Programs`**, which already reads a configured list and
   re-stats `installed?` on every call — deliberately, so a program that
   appears on the data partition after boot shows up without a restart. That
   was written for exactly this.

## The open question

**Is the writable partition mounted `exec`?** Everything above depends on it
and it is *not yet verified*. `fwup_include/fwup-common.conf:19-21` puts an
f2fs application partition on `/dev/mmcblk0p4` mounted at `/root`, and
specifies no mount options, so the default (exec permitted) should apply. That
is an inference, not a reading.

One command settles it, next time the device is up:

```elixir
# on the device
File.write!("/root/exectest.sh", "#!/bin/sh\necho ok\n")
File.chmod!("/root/exectest.sh", 0o755)
System.cmd("/root/exectest.sh", [])   # {"ok\n", 0} means exec works
```

If it turns out to be `noexec`, route B is dead in this form and the fallback
is a dedicated read-only content partition written by fwup — which does touch
the system repo, but generically, as "a content partition" rather than as
RetroArch.

## Build reference

`docs/retroarch-reference/` holds a Buildroot package for RetroArch 1.22.2
written before this decision. It is kept because the expensive part — the
configure flag set for a KMS/DRM, no-X11, no-Wayland, GLES target — transfers
directly to whatever drives the cross build.

Treat its comments with suspicion. An adversarial review checked them against
the real v1.22.2 tarball and found several stated as observed and false:

- "grepping `EGL_NO_X11` across the tree matches zero files" — it matches two.
- "`media/assets` is a git submodule" — there is no `.gitmodules` at all.
- `--disable-neon` is described as a guard that must not be removed; NEON is
  already off by default at that tag, so the flag is a no-op.
- An undeclared optional dependency on fontconfig: `qb/config.libs.sh:540`
  probes for it ungated and there is no `--disable-fontconfig` to turn it off.

The flags themselves were not shown to be wrong. Nothing here has ever been
built.
