import Config

# This board has no external RTC, so erlinit advances a stale clock at boot.
config :nerves, :erlinit, update_clock: true

# Facts specific to the physical RG40XXV. Shared application paths, bundles,
# cores, systems and release behaviour remain in target.exs.
config :mayonnaios, :device, %{
  id: :rg40xxv,
  name: "RG40XXV",
  panel_size: {640, 480},
  inputs: %{
    gamepad: "gpio-keys-gamepad",
    stick: "adc-joystick",
    volume: "gpio-keys-volume",
    headphone: "H616 Audio Codec Headphone Jack",
    power: "axp20x-pek"
  },
  # These are physical verbs mapped to the atoms InputEvent emits. The
  # RG40XXV device tree swaps both A/B and X/Y for this shell.
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
  leds: %{green: "green:power", red: "green:status"},
  power_supplies: %{
    battery: "/sys/class/power_supply/axp20x-battery",
    usb: "/sys/class/power_supply/axp20x-usb"
  },
  games_card_device: "/dev/mmcblk2p1",
  backlight: "/sys/class/backlight/backlight/brightness",
  lid_switch: nil,
  rtc?: false
}
