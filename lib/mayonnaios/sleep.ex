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

  A suspend would at least be recoverable -- the power key's platform device
  is wakeup-capable and enabled, `/sys/bus/platform/devices/axp20x-pek/power/wakeup`
  reads `enabled` on firmware `3cc86f59` -- but the three reasons above decide
  it regardless: no `deep`, an s2idle that aborts in rtw88, and no cpuidle
  driver to make a successful one worth anything. So sleep is the backlight
  and nothing else.

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

  ## The binding

  The binding is the power button. It is on
  the PMIC's PWRON pin, `CONFIG_INPUT_AXP20X_PEK` is set in the system repo's
  `linux/nerves.fragment`, and `drivers/input/misc/axp20x-pek.c` puts
  `KEY_POWER` on an input device named `axp20x-pek`. Read off the device on
  firmware `3cc86f59`:

      /dev/input/event0  axp20x-pek  report_info: [ev_key: [:key_power]]

  One key and nothing else on that device, which is what makes this a binding
  with no modifier. There is no neighbouring button to press by accident, and
  a key that is alone on its own node cannot be half of a chord.

  A short press is this module's. A long one is not, and cannot be made to be:
  the PMIC's own `shutdown` attribute reads `4000`, so holding the button for
  four seconds makes the AXP cut the rail in hardware, without asking Linux
  and without anything being flushed. That is why the orderly ways off --
  `MayonnaiOS.Launcher`'s Select+Menu chord and the menu's Power off row --
  exist and stay off this button.

  Sleep is this button's only trigger. A trigger has to be written down in
  this moduledoc, in the launcher's binding list, in the README, in
  `MayonnaiOS.Keyboard` and in the application's supervision comment, and
  `@binding` below is one tuple precisely so that there is one place where
  any of that is written down.

  `MayonnaiOS.Input.find/1` looks the device up by the name its driver gives
  it, and firmware without the option gets `nil` and a warning naming every
  device that is present, rather than a numbered guess that opens the analog
  stick and waits for `KEY_POWER` for ever.
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

  # `{device name, {modifier, key}}`.
  #
  # The power button, on its own. `nil` for the modifier means the key alone
  # is the trigger; the chord shape is still supported and still resolved at
  # compile time below, so sleep moving back onto the pad -- or onto whatever
  # key the next shell puts it on -- stays a change to this one line.
  #
  # There is no path in here. A fallback would be a number, and a
  # number reached because the name was missing is a different device; see
  # `MayonnaiOS.Input`.
  @binding {"axp20x-pek", {nil, :key_power}}

  # Taken apart at compile time, so the one line above stays the only place
  # any of it is written down.
  @device_name elem(@binding, 0)
  @modifier @binding |> elem(1) |> elem(0)
  @key @binding |> elem(1) |> elem(1)

  @doc """
  The sysfs file that turns the backlight off and on.

  From `config :mayonnaios, :backlight_brightness`, defaulting to the panel's.
  """
  @spec path() :: String.t()
  def path, do: Application.get_env(:mayonnaios, :backlight_brightness, @default_path)

  @doc """
  The input device the sleep key arrives on, or `nil` when there is none.

  Looked up by driver name and by nothing else, because `/dev/input/eventN` is
  probe order and not a promise, and a numbered guess would open some other
  device and wait for a key it never sends. `nil` on a laptop, and on any
  firmware built without `CONFIG_INPUT_AXP20X_PEK`; `MayonnaiOS.Input.find/1`
  has already logged which devices there were instead. See `MayonnaiOS.Input`.
  """
  @spec device() :: String.t() | nil
  def device, do: Input.find(@device_name)

  @doc """
  Whether this press is the sleep trigger, given what is currently held.

  Takes the held set rather than reading it, so the launcher stays the only
  thing that knows about button state and this stays a pure predicate.
  """
  @spec trigger?(MapSet.t(atom()), atom()) :: boolean()
  def trigger?(held, key), do: triggered?(held, key)

  # Which of the two shapes this is, is decided when the module is compiled: a
  # nil modifier -- which is what the power key wants -- makes the key alone
  # the trigger, and then nothing looks at the held set at all. The chord
  # clause is compiled only when `@binding` names a modifier, so a `held` set
  # is still threaded through `trigger?/2` by every caller: that argument is
  # what keeps moving the binding back onto the pad a one-line change.
  if @modifier do
    defp triggered?(held, key), do: key == @key and MapSet.member?(held, @modifier)
  else
    defp triggered?(_held, key), do: key == @key
  end

  @doc """
  The binding, for a log line or a help screen that wants to name it.

  `{nil, key}` when the key is the whole trigger, which is what it is now.
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
