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
3. **`MayonnaiOS.Programs`**, which already reads a configured list and
   re-stats `installed?` on every call — deliberately, so a program that
   appears on the data partition after boot shows up without a restart. That
   was written for exactly this.

## The load-bearing question, now answered

**The writable partition allows execution.** Checked on the device rather
than inferred: a script was written to it, `chmod 0755`, and run.

    /dev/mmcblk0p4 on /root type f2fs (rw,lazytime,nodev,relatime,...)

    /root -> EXEC WORKS
    /data -> EXEC WORKS

`nodev` is set; `noexec` is not. `/data` is a symlink to `root`, so both names
are the same f2fs partition.

Space is not a constraint either, and the contrast is the argument for this
whole approach in two lines:

    /dev/root         66.5M   66.5M       0  100%  /
    /dev/mmcblk0p4    13.7G  279.1M   13.4G    2%  /root

The read-only rootfs is completely full at 66.5 MB. The writable partition has
13.4 GB free. A 100 MB emulator payload does not fit in the first and
disappears into the second — before considering ROMs, save states and
thumbnails, which are pure content and belong there regardless.

So route B stands, and the fallback (a dedicated read-only content partition
written by fwup, which would touch the system repo) is not needed.

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
