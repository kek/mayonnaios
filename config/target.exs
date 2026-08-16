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
config :scenic_rg40xxv, :viewport,
  name: :main_viewport,
  size: {640, 480},
  theme: :dark,
  default_scene: ScenicRg40xxv.Scene.Home,
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
config :scenic_rg40xxv, :programs, [
  %{name: "Spinning cube (kmscube)", path: "/usr/bin/kmscube"},

  # Not in the firmware. This path only exists once ScenicRg40xxv.Bundle has
  # installed RetroArch onto the writable partition, and until then Programs
  # renders it as a greyed, unlaunchable row -- which is the honest state and
  # better than hiding it, since "the menu is empty" gives nobody anything to
  # act on.
  #
  # `current` is a symlink to the installed version, so an upgrade or a
  # rollback moves the link and this path never changes.
  %{name: "RetroArch", path: "/root/bundles/retroarch/current/bin/retroarch"}
]

# Where ScenicRg40xxv.Bundle installs content. On the f2fs application
# partition, which has 13.4 GB free and -- verified on the device, not assumed
# -- is mounted nodev but not noexec, so binaries there can actually run.
config :scenic_rg40xxv, bundle_root: "/root/bundles"

# Scenic validates driver options strictly and raises on an unknown key. An
# `opts:` key here (a reasonable guess, and wrong) took the whole application
# down at boot, so StartupGuard never validated and U-Boot reverted to the
# other slot on the next boot -- losing the device and the error message with
# it. The valid keys are: name, limit_ms, layer, opacity, debug, debugger,
# debug_fps, antialias, calibration, position, window, cursor, key_map,
# on_close, input_blacklist.
config :scenic_rg40xxv, autostart_ui: true

# Audio works, so the test tone is armed. Press Y for a second of 440 Hz.
#
# It stayed off until the speaker had been heard, because the answer was
# worth having in the right order: the mixer powers on muted, so playing
# first would have produced silence and that silence would have been read as
# a fault in the device tree inherited from the RG35XX Plus. It is not --
# unmute first and the routing is fine.
#
# Note this only controls the *test tone*. `ScenicRg40xxv.Audio.unmute/0`
# runs at boot regardless, because the mixer resets to muted every power-on
# and there is no saved ALSA state to restore.
config :scenic_rg40xxv, audio_test: true

# Import target specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
# Uncomment to use target specific configurations

# import_config "#{Mix.target()}.exs"
