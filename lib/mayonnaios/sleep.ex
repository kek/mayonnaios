defmodule MayonnaiOS.Sleep do
  @moduledoc """
  Turns the panel's backlight off and on again.

  This is the whole of "sleep" on this device, and the name is deliberately
  the user's word rather than the kernel's: nothing is suspended, no process
  is stopped, and the CPUs keep running. What changes is the one thing that
  costs anything -- the panel and its backlight are the budget, with the whole
  board measured at about 1.83 W idle with the screen on.

  ## Why it is not suspend

  `/sys/power/mem_sleep` on this board offers only `[s2idle]`. There is no
  `deep`, because ATF's `sun50i_h616` platform does not implement PSCI
  SYSTEM_SUSPEND, and an s2idle attempt aborts anyway inside rtw88's SDIO
  suspend handler with `-EINVAL` (there is no `keep-power-in-suspend` in any
  device tree here). There is also no cpuidle driver, so the deepest state
  these cores reach is a bare WFI whether "suspended" or not: a successful
  s2idle would save almost nothing.

  And it would be dangerous. **No button on the front of this device is
  wakeup-capable** -- only `alarmtimer.0.auto`, `musb-hdrc.2.auto` and
  `7000000.rtc` have a `power/wakeup` at all. A system suspend that worked
  would look exactly like a brick in someone's hands.

  ## Why the backlight, and why 0 and 1

  `/sys/class/backlight/backlight/brightness` is mode 0644 and its
  `max_brightness` is `1`: the panel's backlight is a GPIO (PD28, driven by
  `gpio-backlight`) and not a PWM, because there is no mainline H616 PWM
  driver and adding one was estimated at some 1900 lines of out-of-tree patch.
  So this writes `0` or `1`, straight through to `gpiod_set_value_cansleep`.
  A PWM backlight would need this module to read `max_brightness` and restore
  a previous level; a binary one has nothing to remember.

  Nothing else has to cooperate. Scenic renders through `cairo-fb` into
  `/dev/fb0` on the CPU -- a plain mmap writer, not a DRM master -- so the app
  keeps running with the panel dark, and turning the backlight back on shows
  the current frame with no re-init and no scene restart.

  ## What a successful write does and does not prove

  It proves the GPIO was set. It does not prove the panel went dark, and this
  module cannot find that out:

    * `actual_brightness` is not a hardware readout. `gpio-backlight` has no
      `get_brightness` op, so it echoes what was last set.

    * `/sys/class/graphics/fb0/blank` is writable and lies. `fb_blank()`
      records the requested value before calling the driver,
      `drm_fb_helper_blank()` returns 0 unconditionally and
      `drm_fb_helper_dpms()` is `void`, so a successful write there means only
      that the write was accepted. There is live evidence of exactly that on
      this device: `fb0/blank` reads `4` (POWERDOWN) while the backlight reads
      `1` and DSI-1 dpms reads `On`. It is not used here for that reason.

  So `asleep?/0` reports what was last written, and says so. Whether the panel
  is dark is answerable by looking at the device and by nothing else.

  A write that fails is returned and logged rather than swallowed, because a
  sleep that silently does not sleep is this project's characteristic failure
  -- an inherited assumption reported as success -- and the caller uses the
  answer: `MayonnaiOS.Launcher` only starts swallowing button presses if the
  panel really was told to go dark.

  ## The binding, and the power button

  Karl asked for the power button, and the power button does not exist as far
  as Linux is concerned. There are exactly four input devices on this board --
  `adc-joystick`, `gpio-keys-gamepad`, `gpio-keys-volume` and
  `H616 Audio Codec Headphone Jack` -- and no power key among them. The button
  is on the PMIC's PWRON pin; mainline has the driver
  (`drivers/input/misc/axp20x-pek.c`, which would expose `KEY_POWER` on an
  input device named `axp20x-pek`), but `CONFIG_INPUT_AXP20X_PEK` appears
  nowhere in the system repo -- not in `linux/nerves.fragment`, not in
  `linux/linux-6.18.defconfig`. Enabling it is a one-line kernel config change
  and a 2-3 hour Buildroot rebuild, and no device-tree change at all, since it
  is an MFD cell rather than a DT node.

  Until that rebuild happens the trigger is a chord on the pad, and `@binding`
  below is one line so that the day the key exists, moving sleep onto it is
  one line:

      @binding {"axp20x-pek", "/dev/input/event0", {nil, :key_power}}

  `MayonnaiOS.Input.find/2` is what makes that safe in both directions: it
  looks the device up by the name its driver gives it and falls back to a
  path, so firmware without the option still finds the pad and the chord keeps
  working.
  """

  require Logger

  alias MayonnaiOS.Input

  # The brightness file. Configurable rather than written out at each use, so
  # a test can point it at a temp file and so a panel wired differently is a
  # config line instead of a patch.
  @default_path "/sys/class/backlight/backlight/brightness"

  # max_brightness is 1; see the moduledoc.
  @off "0"
  @on "1"

  # `{device name, path to fall back on, {modifier, key}}`.
  #
  # Select+Start. Select because it is already the modifier this launcher uses
  # and a second modifier would be a second thing to remember; Start because
  # the launcher binds it to nothing at all, so the chord cannot be half of an
  # existing action the way Select+X would be, and because Select and Start
  # are the two recessed buttons in the middle of the shell -- nobody's thumb
  # is resting on them while playing, which is what "cannot be pressed by
  # accident" has to mean on a handheld.
  #
  # Not Menu: Select+Menu powers off, and the reason that chord is guarded is
  # that Menu is the key someone mashes to get out of a game. Not Y, which is
  # deliberately unbound and stays that way.
  #
  # A `nil` modifier means the key alone is the trigger, which is what the
  # real power button will want.
  @binding {"gpio-keys-gamepad", "/dev/input/event0", {:btn_select, :btn_start}}

  # Taken apart at compile time, so the one line above stays the only place
  # any of it is written down.
  @device_name elem(@binding, 0)
  @device_fallback elem(@binding, 1)
  @modifier @binding |> elem(2) |> elem(0)
  @key @binding |> elem(2) |> elem(1)

  @doc """
  The sysfs file that turns the backlight off and on.

  From `config :mayonnaios, :backlight_brightness`, defaulting to the panel's.
  """
  @spec path() :: String.t()
  def path, do: Application.get_env(:mayonnaios, :backlight_brightness, @default_path)

  @doc """
  The input device the sleep key arrives on.

  Looked up by driver name with a path fallback, because `/dev/input/eventN`
  is probe order and not a promise. See `MayonnaiOS.Input`.
  """
  @spec device() :: String.t()
  def device, do: Input.find(@device_name, @device_fallback)

  @doc """
  Whether this press is the sleep trigger, given what is currently held.

  Takes the held set rather than reading it, so the launcher stays the only
  thing that knows about button state and this stays a pure predicate.
  """
  @spec trigger?(MapSet.t(atom()), atom()) :: boolean()
  def trigger?(held, key), do: triggered?(held, key)

  # Which of the two shapes this is, is decided when the module is compiled:
  # a nil modifier -- what the real power key will want -- makes the key alone
  # the trigger, and then nothing looks at the held set at all.
  if @modifier do
    defp triggered?(held, key), do: key == @key and MapSet.member?(held, @modifier)
  else
    defp triggered?(_held, key), do: key == @key
  end

  @doc """
  The chord, for a log line or a help screen that wants to name it.
  """
  @spec binding() :: {atom() | nil, atom()}
  def binding, do: {@modifier, @key}

  @doc """
  Backlight off. `{:error, reason}` when the write does not land.
  """
  @spec sleep() :: :ok | {:error, File.posix()}
  def sleep, do: write(@off, "off")

  @doc """
  Backlight on. `{:error, reason}` when the write does not land.
  """
  @spec wake() :: :ok | {:error, File.posix()}
  def wake, do: write(@on, "on")

  @doc """
  Whether the backlight was last set to off.

  This is what was written, not what the panel is doing; see the moduledoc.
  An unreadable file is reported as awake, because "we cannot tell" must not
  become "the screen is off" -- that reading is the one that would make a
  caller swallow the button presses of someone looking at a lit screen.
  """
  @spec asleep?() :: boolean()
  def asleep? do
    case File.read(path()) do
      {:ok, contents} ->
        String.trim(contents) == @off

      {:error, reason} ->
        Logger.warning("[sleep] #{path()} unreadable: #{inspect(reason)}")
        false
    end
  end

  # Writing the value it already has is a no-op in sysfs and an :ok here, so
  # both directions are idempotent: two sleeps leave it asleep, two wakes
  # leave it awake, and neither has any state of its own to disagree with.
  defp write(value, label) do
    case File.write(path(), value) do
      :ok ->
        Logger.info("[sleep] backlight #{label}")
        :ok

      {:error, reason} ->
        # Warning, with the path in it. The plausible failures are a
        # read-only or absent sysfs node and EACCES, and each of those is a
        # different mistake in a different file.
        Logger.warning("[sleep] cannot turn the backlight #{label}: #{path()} #{inspect(reason)}")
        {:error, reason}
    end
  end
end
