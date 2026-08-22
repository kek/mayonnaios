defmodule MayonnaiOS.Dev do
  @moduledoc """
  Buttons for a laptop, so scenes can be driven without the handheld.

  The host has no `/dev/input` at all, so `MayonnaiOS.Launcher` starts with no
  device and simply never receives anything. It still handles the messages the
  real driver would send, though, which is all this needs: each function here
  sends one synthetic evdev press and lets the Launcher do exactly what it
  would do on the device -- move the cursor, re-root the viewport, launch a
  program.

  That is the point. Driving the scene through the Launcher exercises the
  bindings, the wrap-around and the repaint; calling
  `MayonnaiOS.reload_ui/2` with an index only exercises the drawing.

  ## Expect this in the log, and ignore it

      [error] Scene exited or crashed before it was done initializing.
      module: MayonnaiOS.Scene.Home, reason: :shutdown

  Scenic (0.12.0-rc.0) logs that when `set_root/3` replaces a scene, which is
  what every cursor move does. It appears on the host and means nothing: the
  cursor moves, the new scene draws, `selected/0` agrees. It is noise from
  the replacement itself rather than a failure -- worth knowing because it
  says `[error]` and names a scene, which reads like a real fault in the
  Launcher when it is not one.

      iex> MayonnaiOS.Dev.start()
      iex> MayonnaiOS.Dev.down()
      1
      iex> MayonnaiOS.Dev.a()

  `start/0` also starts `MayonnaiOS.Keyboard`, so the window responds to the
  keyboard directly -- arrows to move, `z` to launch, `enter` for Menu. These
  functions remain useful for scripting a sequence and for asserting on
  `selected/0` without a window in focus.

  ## The names here are the ones on the plastic

  Linux's `BTN_A` is south and `BTN_B` is east, this board follows the Nintendo
  layout, and its device tree mislabels X and Y on top of that -- so the atom
  `:btn_b` is the button silkscreened **A**, and `:btn_y` is the one
  silkscreened **X**. `MayonnaiOS.Launcher`'s moduledoc has the full account.
  Every function below is named after the physical button and sends whichever
  atom that button really emits, so this module is also a legible statement of
  the mapping.
  """

  alias MayonnaiOS.Launcher

  # Physical button -> the atom InputEvent actually decodes for it.
  @buttons %{
    a: :btn_b,
    b: :btn_a,
    x: :btn_y,
    y: :btn_x,
    menu: :btn_mode,
    select: :btn_select,
    up: :btn_dpad_up,
    down: :btn_dpad_down
  }

  @doc """
  Start the viewport and the Launcher, if they are not up already.

  Safe to call twice; returns the selected index so there is something to
  compare against after the first press.
  """
  def start do
    if is_nil(Process.whereis(:main_viewport)), do: MayonnaiOS.start_ui()

    if is_nil(Process.whereis(Launcher)) do
      {:ok, _} = Launcher.start_link([])
    end

    # The keyboard bridge, so the window is usable with hands as well as with
    # function calls. Started after the Launcher, because it sends to it.
    if is_nil(Process.whereis(MayonnaiOS.Keyboard)) do
      {:ok, _} = MayonnaiOS.Keyboard.start_link([])
    end

    selected()
  end

  @doc "The highlighted row, straight from the Launcher."
  def selected, do: Launcher.selected()

  for {name, key} <- @buttons do
    @doc "Press the button marked #{String.upcase(to_string(name))} (sends `#{inspect(key)}`)."
    def unquote(name)(), do: press(unquote(key))
  end

  @doc """
  Press the power button: the backlight goes off, and any press brings it back.

  Not in the table above, because it is not on the pad. On the device this
  arrives from `axp20x-pek` rather than from the gamepad; the Launcher reads
  both nodes and does not look at which one a report came from, so one
  synthetic `:key_power` exercises the same path.
  """
  def power, do: press(:key_power)

  @doc """
  Press and hold Select, then Menu: the power-off chord.

  Not the power button. A short press of that is `power/0` above and sleeps; a
  four-second hold makes the PMIC cut the rail without telling Linux, which is
  why an orderly shutdown is still a chord. See `MayonnaiOS.Sleep`.

  On the device this powers off, so it is spelled out rather than given a
  one-letter name. On the host `Nerves.Runtime.poweroff/0` is a no-op, which
  makes this safe to try and useless to watch.
  """
  def poweroff_chord do
    send_events([{:ev_key, @buttons.select, 1}, {:ev_key, @buttons.menu, 1}])
    selected()
  end

  @doc """
  Send a raw evdev key, for a button with no function here.

      iex> MayonnaiOS.Dev.press(:btn_start)
  """
  def press(key) when is_atom(key) do
    send_events([{:ev_key, key, 1}])
    selected()
  end

  # One synthetic report, shaped exactly like input_event's. The device string
  # is a lie and deliberately an obvious one: the Launcher ignores it, and a
  # plausible-looking device node in a host session would invite the reader to
  # believe something is really open.
  defp send_events(events) do
    send(Launcher, {:input_event, "(MayonnaiOS.Dev)", events})
  end
end
