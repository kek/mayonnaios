import Config

# The RG SP BSP describes mainline's PCF8563 RTC, but no reading of it on this
# board has been checked. Advancing a stale clock is harmless if it does work.
config :nerves, :erlinit, update_clock: true

# The framebuffer is 720x480 XRGB8888 with a 2880-byte stride and no padding.
config :mayonnaios, :viewport, size: {720, 480}

# Facts specific to the physical RG SP. Names come from the BSP's device tree,
# which includes mainline's sun50i-h700-anbernic-rg35xx-sp.dts, and every
# input, LED, power supply and backlight named here is present on the device.
# Which physical key sends which code has not been recorded with evtest.
config :mayonnaios, :device, %{
  id: :rgsp,
  name: "RG SP",
  panel_size: {720, 480},
  inputs: %{
    gamepad: "gpio-keys-gamepad",
    # No analog stick on this shell.
    stick: nil,
    volume: "gpio-keys-volume",
    headphone: "H616 Audio Codec Headphone Jack",
    power: "axp20x-pek"
  },
  # The same gpio-keys-gamepad node as the RG40XXV, so the same A/B and X/Y
  # swap for this shell.
  buttons: %{
    launch: :btn_b,
    confirm: :btn_x,
    actions: :btn_x,
    full: :btn_y,
    poweroff_modifier: :btn_select,
    home: :btn_mode,
    up: :btn_dpad_up,
    down: :btn_dpad_down,
    left: :btn_dpad_left,
    right: :btn_dpad_right,
    page_up: :btn_tl,
    page_down: :btn_tr,
    back: :btn_a,
    sleep: :key_power
  },
  # Mainline's two gpio-leds on PI12 and PI11. Which colours they shine on
  # this shell is not known.
  leds: %{green: "green:power", red: "green:status"},
  power_supplies: %{
    battery: "/sys/class/power_supply/axp20x-battery",
    usb: "/sys/class/power_supply/axp20x-usb"
  },
  # The games slot is mmc2 in the device tree. The block device name is probe
  # order and has not been observed with a card in it.
  games_card_device: "/dev/mmcblk2p1",
  # gpio-backlight: on or off, no levels.
  backlight: "/sys/class/backlight/backlight/brightness",
  lid_switch: %{device: "gpio-keys-lid", key: :sw_lid},
  rtc?: false
}
