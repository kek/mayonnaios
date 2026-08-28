import Config

# Use Ringlogger as the logger backend and remove :console.
# See https://ring-logger.hexdocs.pm/readme.html for more information on
# configuring ring_logger.

config :logger, backends: [RingLogger]

# Use shoehorn to start the main application. See the shoehorn
# library documentation for more control in ordering how OTP
# applications are started and handling failures.

config :shoehorn, init: [:nerves_runtime, :nerves_pack]

# Enable the system startup guard to check that all OTP applications
# started. If they didn't and you're on a Nerves system that supports
# test runs of new firmware, the firmware will automatically roll
# back to the previous version. Delete this if implementing your own
# way of validating that firmware is good.
config :nerves_runtime, startup_guard_enabled: true

# Erlinit can be configured without a rootfs_overlay. See
# https://github.com/nerves-project/erlinit/ for more information on
# configuring erlinit.

# Advance the system clock on devices without a real-time clock.
config :nerves, :erlinit, update_clock: true

# Configure the device for SSH IEx prompt access and firmware updates
#
# * See https://nerves-ssh.hexdocs.pm/readme.html for general SSH configuration
# * See https://ssh-subsystem-fwup.hexdocs.pm/readme.html for firmware updates

keys =
  System.user_home!()
  |> Path.join(".ssh/id_{rsa,ecdsa,ed25519}.pub")
  |> Path.wildcard()

if keys == [],
  do:
    Mix.raise("""
    No SSH public keys found in ~/.ssh. An ssh authorized key is needed to
    log into the Nerves device and update firmware on it using ssh.
    See your project's config.exs for this error message.
    """)

config :nerves_ssh,
  authorized_keys: Enum.map(keys, &File.read!/1)

wifi = fn var ->
  System.get_env(var) ||
    raise """
    #{var} is not set.

    This device has no other way in: the USB-C gadget is unreliable here and
    UART0 is on internal test pads, so firmware that boots without working
    WiFi credentials has to be recovered by reflashing the card.

        export RG40XXV_WIFI_SSID="your-ssid"
        export RG40XXV_WIFI_PSK="your-psk"
    """
end

# Configure the network using vintage_net
#
# Update regulatory_domain to your 2-letter country code E.g., "US"
#
# See https://github.com/nerves-networking/vintage_net for more information
config :vintage_net,
  regulatory_domain: "00",
  config: [
    {"usb0", %{type: VintageNetDirect}},
    {"eth0",
     %{
       type: VintageNetEthernet,
       ipv4: %{method: :dhcp}
     }},
    # WiFi is the only way onto this device: the USB-C gadget has not been
    # seen enumerating, and UART0 is on internal test pads. Firmware built
    # without working credentials here is unreachable until the card is
    # reflashed by hand -- which has already happened once.
    #
    # Credentials come from the build environment so they are not committed.
    # Missing ones fail the build rather than producing firmware that cannot
    # be reached -- but with a message that says what to do, since this is
    # evaluated for every mix task on this target, `deps.get` included.
    {"wlan0",
     %{
       type: VintageNetWiFi,
       vintage_net_wifi: %{
         networks: [
           %{
             key_mgmt: :wpa_psk,
             ssid: wifi.("RG40XXV_WIFI_SSID"),
             psk: wifi.("RG40XXV_WIFI_PSK")
           }
         ]
       },
       ipv4: %{method: :dhcp}
     }}
  ]

config :mdns_lite,
  # The `hosts` key specifies what hostnames mdns_lite advertises.  `:hostname`
  # advertises the device's hostname.local. For the official Nerves systems, this
  # is "nerves-<4 digit serial#>.local".  The `"nerves"` host causes mdns_lite
  # to advertise "nerves.local" for convenience. If more than one Nerves device
  # is on the network, it is recommended to delete "nerves" from the list
  # because otherwise any of the devices may respond to nerves.local leading to
  # unpredictable behavior.

  hosts: [:hostname, "nerves"],
  ttl: 120,

  # Advertise the following services over mDNS.
  services: [
    %{
      protocol: "ssh",
      transport: "tcp",
      port: 22
    },
    %{
      protocol: "sftp-ssh",
      transport: "tcp",
      port: 22
    },
    %{
      protocol: "epmd",
      transport: "tcp",
      port: 4369
    }
  ]

# Scenic viewport. The size must match the panel: the framebuffer is
# 640x480 XRGB8888 with a 2560-byte stride and no padding.
#
# Scenic.Driver.Local picks its renderer from MIX_TARGET -- under Nerves that
# is cairo-fb, drawing on the CPU into /dev/fb0. No GPU is involved, which is
# why this path works before Mesa exists.
config :mayonnaios, :viewport,
  name: :main_viewport,
  size: {640, 480},
  theme: :dark,
  default_scene: MayonnaiOS.Scene.Home,
  drivers: [
    [
      module: Scenic.Driver.Local,
      name: :local
    ]
  ]

# What the launcher menu offers. The D-pad moves the cursor, A starts the
# highlighted entry.
#
# Paths are absolute because `Port.open({:spawn_executable, ...})` does not go
# through a shell and does not search $PATH. A bare "kmscube" would not fail
# on screen as "not installed" -- it would look launchable, and then die with
# :enoent at the moment the button was pressed.
#
# Only kmscube is listed, because only kmscube is known to exist in this image
# and to hold the display until it is stopped. A second entry such as
# `kmscube -M smooth` is plausible and untested; an entry that exits instantly
# with a usage message would look exactly like a working launcher.
#
#     %{name: "Spinning cube (smooth)", path: "/usr/bin/kmscube", args: ["-M", "smooth"]}
config :mayonnaios, :programs, [
  # Not in the firmware. This path only exists once MayonnaiOS.Bundle has
  # installed RetroArch onto the writable partition, and until then Programs
  # renders it as a greyed, unlaunchable row -- which is the honest state and
  # better than hiding it, since "the menu is empty" gives nobody anything to
  # act on.
  #
  # `current` is a symlink to the installed version, so an upgrade or a
  # rollback moves the link and this path never changes.
  #
  # needs_udev because RetroArch reads the gamepad through udev and has no
  # other way to: linuxraw sees only console keycodes, there is no plain evdev
  # driver, and this kernel has no joydev. The Launcher starts udevd and
  # replays the input uevents before launching anything with this flag.
  #
  # --appendconfig layers the bundle's directory paths over the player's own
  # config rather than replacing it. RetroArch writes settings back to its main
  # config, and the bundle is replaced wholesale on upgrade, so the two must
  # not be the same file: settings live in /root/.config/retroarch and survive,
  # while these paths follow whichever bundle is installed. The build sets
  # --prefix=/ so the compiled-in defaults point at /usr/share/retroarch, which
  # does not exist here -- the rootfs is read-only and the bundle is not in it.
  %{
    name: "RetroArch",
    path: "/root/bundles/retroarch/current/bin/retroarch",
    # Two files, and the order is the point. `--appendconfig` takes a
    # `|`-separated list and merges each in turn, so the last one wins.
    #
    # Bundles up to v1.22.2-5 set `libretro_directory` themselves, naming
    # /root/retroarch/cores -- a directory nothing fills. With only that file
    # appended, RetroArch showed an empty core list on every launch and wrote
    # the bad value back into the player's config on exit, which
    # `MayonnaiOS.Cores.clear_stale_directory/0` then removed at the next boot
    # and the next launch put back. Repaired once per boot, broken once per
    # launch.
    #
    # v1.22.2-6 sets no directory at all, so for a device that has installed it
    # there is nothing to argue with. The second file stays anyway, because a
    # value persisted by an older bundle outlives that bundle and no later
    # bundle can withdraw it. It is written by
    # `MayonnaiOS.Cores.write_append_config/0` from `Cores.dir/0`, so it names
    # the directory the symlinks actually go into, cannot drift from it, and
    # being last it wins over anything a bundle or an earlier run left behind.
    #
    # That file now also carries `audio_sync = "false"`, which is a guard
    # against a stalled codec freezing a game in `poll()` rather than a
    # preference about audio. It is in this file rather than a bundle's for the
    # same reason as the directory -- this one can be withdrawn -- and the
    # withdrawal is a boot-time scrub of the player's own config. See that
    # function.
    #
    # The `|` never meets a shell: `Port.open/2` with `:spawn_executable` passes
    # argv straight through, so this is one argument containing a pipe rather
    # than two commands.
    args: [
      "--appendconfig",
      "/root/bundles/retroarch/current/share/retroarch/retroarch.cfg" <>
        "|/root/.config/retroarch/mayonnaios.cfg"
    ],
    needs_udev: true
  },
  # Game streaming from a Sunshine or GeForce host, decoded in software on
  # the A53s and drawn through SDL on the same KMS stack RetroArch uses.
  # Until the bundle is installed this is a visible, unlaunchable row --
  # `MayonnaiOS.Programs` stats the path on every render.
  #
  # -config names the player's own file rather than the bundle's, because the
  # one thing a stream cannot start without is the host's address, and no
  # bundle can know it. The file does not exist until the player creates it
  # over SSH -- the same session in which they pair, since pairing prints a
  # PIN that must be typed into the host:
  #
  #     /root/bundles/moonlight/current/bin/moonlight pair <host>
  #     cp /root/bundles/moonlight/current/share/moonlight/moonlight.conf \
  #        /root/.config/moonlight/moonlight.conf
  #     echo 'address = <host>' >> /root/.config/moonlight/moonlight.conf
  #
  # The bundle's template carries the hardware-dictated defaults (720p30,
  # h264, SDL) and comments on what to lower first if decode cannot keep up.
  %{
    name: "Moonlight",
    path: "/root/bundles/moonlight/current/bin/moonlight",
    args: ["stream", "-config", "/root/.config/moonlight/moonlight.conf"],
    needs_udev: true
  },
  %{name: "Spinning cube (kmscube)", path: "/usr/bin/kmscube"},
  %{name: "Spinning cube (smooth)", path: "/usr/bin/kmscube", args: ["-M", "smooth"]},
  # An app rather than a program: a module in this firmware, started in this
  # VM, with no external process and no screen handed over. See
  # `MayonnaiOS.Programs` for what that distinction costs and buys.
  #
  # It takes hci0 for as long as it runs, so it cannot be up at the same time
  # as anything else that wants the Bluetooth controller. That is why it is
  # here as a menu entry and not in the boot supervision tree.
  #
  # `category: :apps` puts it in the launcher's Apps column, next to the
  # pickles: it is a thing to use, not a setting. Rows without a category are
  # classified by `MayonnaiOS.Browser`.
  %{name: "Bluetooth controller", app: MayonnaiOS.Controller, category: :apps},
  # There is no file manager row: the launcher's own Files column *is* the
  # file manager. It reaches only the roots `MayonnaiOS.Files` derives from
  # the configuration below -- the ROM roots, the bundles, the cores, /root,
  # and `/` for the whole filesystem -- and it builds every path from a root
  # key plus checked names rather than from a string. See that module's
  # moduledoc for what the boundary does and does not promise; the symlink
  # caveat is the part worth reading.
  #
  # The other direction, and it takes hci0 for the same reason, so these two
  # are mutually exclusive and the launcher's one-app-at-a-time rule is what
  # enforces it.
  #
  # Named "devices" rather than "pairing" deliberately. What it does is list
  # what is nearby and manage the pairings this device already has; it cannot
  # connect headphones, because that is A2DP over BR/EDR and there is no
  # BR/EDR host in this firmware. `MayonnaiOS.Pairing` has the full account,
  # and the screen says it in the first line rather than in a footnote.
  %{name: "Bluetooth devices", app: MayonnaiOS.Pairing},
  # Two rows, one app: `MayonnaiOS.Top` with which world to read as the
  # argument, the same {module, arg} shape graphical pickles use. Both are
  # readings of things that are always there -- the VM and /proc -- so unlike
  # the Bluetooth apps neither takes a device away from anything.
  %{name: "BEAM processes", app: {MayonnaiOS.Top, :beam}},
  %{name: "OS processes", app: {MayonnaiOS.Top, :os}},
  # Checks kek/mayonnaios's GitHub releases for a newer version than the one
  # running, and downloads and applies it with fwup if there is one -- the
  # online half of what `mix upload` does from a dev machine. See
  # `MayonnaiOS.Update`'s moduledoc for the download/apply/validate flow and
  # why nothing here has to call `Nerves.Runtime.validate_firmware/0` itself.
  %{name: "Software update", app: MayonnaiOS.Update.App},
  # Neither a program nor an app: a verb of the launcher's own. Selecting it
  # asks rather than acts -- Y answers, anything else cancels -- and it ends
  # in the same `Nerves.Runtime.poweroff/0` the Select+Menu chord reaches.
  # Last on purpose: the off switch belongs at the end of a list you scroll,
  # not next to the thing you launch every day.
  %{name: "Power off", action: :poweroff}
]

# The name a host shows in its pairing list, and the icon it draws next to it
# comes from the gamepad appearance in the advertisement rather than from this.
#
# The real controller's name, because the name is part of the claimed
# identity -- see `MayonnaiOS.Bluetooth.HOGP`. At 24 bytes it fits the
# 31-byte scan response it shares with nothing else;
# `MayonnaiOS.Bluetooth.Advertising` shortens anything past 29 bytes and a
# truncated name is what a host caches.
config :mayonnaios, controller_name: "Xbox Wireless Controller"

# Where the keys of paired hosts are written.
#
# On the writable application partition, not the read-only rootfs, and not
# under /tmp: the whole point of a bond is that it survives a power cut, which
# on this device is how it is switched off. Losing the file costs one
# re-pairing per host and nothing else.
config :mayonnaios, bond_path: "/root/bluetooth/bonds.bin"

# Where MayonnaiOS.Bundle installs content. On the f2fs application
# partition, which has 13.4 GB free and -- verified on the device, not assumed
# -- is mounted nodev but not noexec, so binaries there can actually run.
config :mayonnaios, bundle_root: "/root/bundles"

# Where pickles -- sandboxed Lua apps, see MayonnaiOS.Pickles -- are
# installed. Same partition as bundles and for the same reason: content, not
# firmware.
config :mayonnaios, pickles_root: "/root/pickles"

# Bundles this device knows how to install, by name.
#
# The SHA-256 is the trust anchor and it lives here, in the firmware, rather
# than being fetched alongside the tarball -- a checksum served next to the
# thing it describes is not evidence about anything. So the download is
# untrusted and this line is what decides whether the bytes are used.
#
# Installing is deliberately not automatic. It happens when asked:
#
#     iex> MayonnaiOS.Bundle.install(MayonnaiOS.Bundle.spec(:retroarch))
#
# Built by github.com/kek/mayonnaios_bundles against this system's own staging
# sysroot, so the sonames match what the rootfs ships.
#
# `version` must change whenever the tarball does, and it is the *release*
# version rather than RetroArch's own for exactly that reason. It names the
# install directory, and `publish/3` does `File.rm_rf` on that directory
# before renaming the new one into place -- so reusing a version to ship a
# rebuild would delete the directory the running RetroArch was launched from.
# The -N suffix counts rebuilds of the same upstream release, which is what
# every one of these has been so far.
config :mayonnaios, :bundles, %{
  retroarch: %{
    name: "retroarch",
    version: "1.22.2-7",
    url:
      "https://github.com/kek/mayonnaios_bundles/releases/download/v1.22.2-7/retroarch-1.22.2-aarch64.tar.gz",
    sha256: "fcfeafdf307afac56666a3c9f5004880bee3b9326401a720fe269338ce80824c"
  },
  # The sha256 is the one CI printed for the tarball it attached to the
  # moonlight-v2.7.1-1 release -- the release asset, not a local build, since
  # two builds of the same sources are not byte-identical across machines.
  moonlight: %{
    name: "moonlight",
    version: "2.7.1-1",
    url:
      "https://github.com/kek/mayonnaios_bundles/releases/download/moonlight-v2.7.1-1/moonlight-2.7.1-aarch64.tar.gz",
    sha256: "9208fc553210f82cb07828cd13e7d16609ec0734d540a36ceb33e17af44147db"
  }
}

# The game library, and the systems the upload page offers.
#
# The key is the directory name under :rom_root and it is never taken from a
# request -- a request supplies a key, this list turns it into a path. That is
# what makes the directory component of an upload URL safe without any
# sanitising: an unknown key is a 404, not a traversal.
#
# Extensions are the accept-list. `.zip` is in each of them because RetroArch
# reads zipped ROMs directly and phones like to hand over archives.
# The card in the second SD slot. mmcblk2, not mmcblk1 -- the first slot is
# the OS card and mmcblk1 is the SDIO WiFi, so the obvious guess gets the
# radio. Read-write, because adding and deleting games in place is the point
# of a games card; see MayonnaiOS.GamesCard for what that costs on a
# journal-less filesystem in a device that is switched off by pulling power.
config :mayonnaios, :games_card,
  device: "/dev/mmcblk2p1",
  mount_point: "/root/mnt/games",
  filesystems: ["exfat", "vfat"],
  options: "rw,nosuid,nodev,noexec",
  sync: false

# Where games live, read in order. The first is written: uploads land on the
# internal card because the games card can be out, and an upload that goes
# nowhere is worse than one that goes somewhere always present.
#
# Both are called ROMS. The games card arrived pre-formatted with ROMS/ from
# the stock OS, and one layout across both cards is easier to hold in the head
# than a translation between two -- so the internal directory was renamed to
# match the card rather than the other way round.
config :mayonnaios,
  rom_roots: [
    "/root/ROMS",
    "/root/mnt/games/ROMS"
  ]

config :mayonnaios, :systems, [
  # Chronological, because that is the order these end up in the head and the
  # upload page shows them in list order.
  #
  # No .fds here: fceumm plays Famicom Disk System images, but only with a
  # BIOS this device does not ship, so accepting one would take an upload
  # that cannot be played.
  %{
    key: "nes",
    name: "Nintendo",
    extensions: [".nes", ".unf", ".zip"]
  },
  %{
    key: "snes",
    name: "Super Nintendo",
    extensions: [".sfc", ".smc", ".zip"]
  },
  %{
    key: "gb",
    name: "Game Boy",
    extensions: [".gb", ".zip"]
  },
  %{
    key: "gbc",
    name: "Game Boy Color",
    extensions: [".gbc", ".zip"]
  },
  %{
    key: "gba",
    name: "Game Boy Advance",
    extensions: [".gba", ".zip"]
  }
]

# One gigabyte. Not about space -- there is 13 GB -- but about a request that
# never ends: without a ceiling one client can fill the partition that holds
# the bundles and the saves, and the failure then shows up everywhere except
# where it was caused.
config :mayonnaios, max_upload_bytes: 1_073_741_824

# Cores.
#
# Where cores are, in two parts.
#
# `core_root` holds installed core bundles: real files, one versioned directory
# per core, outside every RetroArch bundle so an upgrade cannot lose them.
#
# `core_dir` is the directory RetroArch reads, and it is RetroArch's own
# default -- ~/.config/retroarch/cores -- rather than a location of our
# choosing. Nothing is copied there: MayonnaiOS.Cores fills it with symlinks
# pointing at the real files, in the bundle and in core_root. So the default
# location is what RetroArch looks in, the actual .so files stay where their
# installer put them, and no RetroArch setting has to name it.
#
# It has to be actively kept that way, which is what Cores.clear_stale_directory/0
# is for. RetroArch takes libretro_directory verbatim -- unlike the save
# directories it does not check that it exists -- and it persists a value
# supplied by --appendconfig into its own config as though the player had set
# it. A stale value therefore outlives the bundle that set it, and presents as
# a console with no cores and nothing in the log about why.
#
# It is under /root, so it survives firmware updates like everything else on
# the app data partition. Cores.sync/0 removes only *.so when it rebuilds, so
# RetroArch's own info files and assets in that directory are left alone.
config :mayonnaios, core_root: "/root/cores"
config :mayonnaios, core_dir: "/root/.config/retroarch/cores"

# The catalogue the upload page offers to install. Same trust model as the
# bundles above: the SHA-256 is here in the firmware, and it is what decides
# whether the downloaded bytes are unpacked at all.
#
# These two also ship inside the RetroArch bundle, so they are already usable
# without installing anything -- `sync/0` finds them there and the page shows
# them as available. The entries exist so a core can be updated on its own,
# without a 2.4 MB bundle download to replace a 1 MB file, and so the
# mechanism is exercised by something real before a core that is *only*
# available this way is added.
#
# The checksums are of the tarballs published on release v1.22.2-5, downloaded
# from that release and hashed here -- not of a local build.
#
# That distinction matters and cost a correction. The same source built on
# this laptop and on the CI runner produces tarballs with different SHA-256s:
# different tar, different timestamps, a compile that is not bit-reproducible.
# Only the published bytes are the ones a device will ever fetch, so a
# checksum taken from a local build would have failed verification on every
# device while being perfectly correct about a file nobody downloads.
config :mayonnaios, :cores, %{
  snes9x2010: %{
    name: "snes9x2010",
    label: "Super Nintendo — Snes9x 2010",
    systems: ["snes"],
    version: "1.22.2-6",
    url:
      "https://github.com/kek/mayonnaios_bundles/releases/download/v1.22.2-6/snes9x2010-1.22.2-aarch64.tar.gz",
    sha256: "9a492c7414330d07929d322bb3b643312eb3bafb7386543484d04b393abb7e85"
  },
  "2048": %{
    name: "2048",
    label: "2048",
    systems: [],
    version: "1.22.2-6",
    url:
      "https://github.com/kek/mayonnaios_bundles/releases/download/v1.22.2-6/2048-1.22.2-aarch64.tar.gz",
    sha256: "c6eba3f077baf5fe56766d8213424c38d5ff0787488d4fac455d4ff96ba86518"
  }
}

# The upload page. Port 80 so the address is just the hostname:
#
#     http://nerves-5322903c.local/
#
# No authentication and no TLS; see the moduledoc on MayonnaiOS.Web for
# what that means and when it should change.
config :mayonnaios, web_port: 80

# Scenic validates driver options strictly and raises on an unknown key. An
# `opts:` key here (a reasonable guess, and wrong) took the whole application
# down at boot, so StartupGuard never validated and U-Boot reverted to the
# other slot on the next boot -- losing the device and the error message with
# it. The valid keys are: name, limit_ms, layer, opacity, debug, debugger,
# debug_fps, antialias, calibration, position, window, cursor, key_map,
# on_close, input_blacklist.
config :mayonnaios, autostart_ui: true

# Audio works, so `MayonnaiOS.Audio.run/0` is allowed to make a sound.
#
# It stayed off until the speaker had been heard, because the answer was
# worth having in the right order: the mixer powers on muted, so playing
# first would have produced silence and that silence would have been read as
# a fault in the device tree inherited from the RG35XX Plus. It is not --
# unmute first and the routing is fine.
#
# The tone is not on a button. It was on Y while audio was the open question;
# now that it is answered, a key that makes noise when brushed in a pocket is
# not worth keeping for a check that belongs in IEx.
#
# This flag only gates the tone. The mixer itself is taken to 0% at boot by
# `MayonnaiOS.Audio.Startup` either way -- volume is something the player asks
# for, not something the device assumes, and the rocker on the top edge is how
# they ask: `MayonnaiOS.Volume` walks the mixer up from silence.
#
# 0% at boot, but *not* switched off any more. Switched off is a device on
# which no program can play at all -- ALSA powers the DAC only when the route
# to the sink is complete, so a closed switch turns a write to the PCM into
# EIO and turns RetroArch into a game frozen in `poll()`. That was the hang.
config :mayonnaios, audio_test: true

# Import target specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
# Uncomment to use target specific configurations

# import_config "#{Mix.target()}.exs"
