defmodule MayonnaiOS.Keyboard do
  @moduledoc """
  Drives the launcher from a keyboard, by pretending to be the gamepad.

  The handheld's buttons reach `MayonnaiOS.Launcher` as evdev reports from
  `/dev/input/event0`. A laptop has no such device, so this process subscribes
  to Scenic's `:key` and `:codepoint` input and re-sends each keystroke in
  exactly the shape the real driver uses:

      {:input_event, device, [{:ev_key, :btn_dpad_down, 1}]}

  Nothing downstream can tell the difference, which is the point. The Launcher's
  bindings, the wrap-around, the repaint and the launch path are all the code
  that runs on the device -- only the source of the press differs. A host-only
  input path in the Launcher, or key handling inside the scenes, would have
  meant testing something the device never executes.

  ## It is not really host-only

  Nothing here is conditional on `Mix.target/0`. Scenic delivers this input
  from whatever the driver offers: a GTK window on a laptop, and a USB keyboard
  on the handheld, which `scenic_driver_local` reads through the same evdev
  layer. So plugging a keyboard into the device gets these bindings too. That
  is a side effect of not special-casing the host, and a welcome one -- it is
  the difference between "works on my laptop" and "works".

  ## Bindings

      up / down / k / j   the D-pad
      z                   A -- launch the highlighted program
      c                   X -- the diagnostics screen
      enter               Menu -- back to the home screen
      backspace           Select
      escape              Select+Menu, the power-off chord

  Arrows and `jk` both move because the arrows are where a hand goes first and
  `jk` is where it goes second. `z` follows the emulator convention for A
  rather than the letter printed on the shell, because the physical layout has
  no left-to-right mapping onto a keyboard worth guessing at.

  `x` and `v` are also sent, as B and Y, and deliberately do nothing: the
  Launcher binds neither. They are here so the mapping is complete and so those
  presses reach the Launcher's unhandled-key logging rather than being dropped
  silently -- if B or Y ever gains a binding, the keyboard already has it.
  """

  use GenServer
  require Logger

  alias MayonnaiOS.Launcher

  # Two tables, because the driver reports letters and named keys through
  # different input classes -- and only one of them works for letters.
  #
  # `:key` carries an atom from the driver's keysym table. On the GTK backend
  # that table (@gdk_key_atoms in scenic_driver_local) maps X11 keysyms and
  # contains only the *uppercase* ASCII range 65..90, so a plain `z` keysym
  # (122) is unmapped and arrives as nothing at all. Shift+Z would work.
  # Arrows, Enter and Escape are fine because their keysyms are not
  # case-dependent, which is exactly why the D-pad worked while z/x/c/v did
  # not. `:codepoint` carries the actual character the keyboard produced, so
  # letters are read from there instead.
  #
  # The values are evdev atoms, not labels: :btn_b is the button silkscreened
  # A and :btn_y is the one silkscreened X, because Linux's BTN_A is south and
  # this board's device tree also has X and Y the wrong way round. The
  # Launcher's moduledoc has the full account; the comments name the physical
  # button so these tables can be read without it.
  @named_keys %{
    key_up: :btn_dpad_up,
    key_down: :btn_dpad_down,
    # Menu: home
    key_enter: :btn_mode,
    key_backspace: :btn_select
  }

  @characters %{
    "k" => :btn_dpad_up,
    "j" => :btn_dpad_down,
    # A: launch
    "z" => :btn_b,
    # B, which the Launcher does not bind -- listed so the mapping is complete
    # and so an unbound press is logged rather than silently dropped.
    "x" => :btn_a,
    # X: diagnostics
    "c" => :btn_y,
    # Y, also unbound in the Launcher
    "v" => :btn_x
  }

  # Escape is the chord rather than a single key, because Select+Menu is
  # awkward to hold on a keyboard and the thing it does is worth reaching.
  # The atom is :key_esc, not :key_escape -- the driver's table spells it
  # short, and the long name silently bound nothing.
  @chord_key :key_esc
  @chord [:btn_select, :btn_mode]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The keyboard bindings, for a scene that wants to draw them as help.
  """
  def bindings, do: %{keys: @named_keys, characters: @characters, chord: @chord_key}

  @impl GenServer
  def init(opts) do
    viewport = Keyword.get(opts, :viewport, viewport_name())

    case subscribe(viewport) do
      :ok ->
        Logger.info("[keyboard] driving the launcher: arrows/jk move, z launches, enter is Menu")
        {:ok, %{viewport: viewport}}

      {:error, reason} ->
        # No viewport is not a reason to fail: the keyboard is a convenience,
        # and this process starting before Scenic is a plausible ordering.
        Logger.warning("[keyboard] no viewport yet (#{inspect(reason)}); no keys bound")
        {:ok, %{viewport: viewport}}
    end
  end

  # Any pid may request input -- Scenic's request/3 takes an explicit :pid --
  # so this does not have to be a scene, and the scenes stay free of input
  # handling they would only need on a laptop.
  defp subscribe(name) do
    with pid when is_pid(pid) <- Process.whereis(name),
         {:ok, vp} <- Scenic.ViewPort.info(pid) do
      Scenic.ViewPort.Input.request(vp, [:key, :codepoint], pid: self())
    else
      nil -> {:error, :no_viewport}
      err -> err
    end
  end

  # Scenic sends requested input as {:_input, input, raw, id}. Value 1 is a
  # press and 0 a release; Scenic also sends 2 for autorepeat, and passing it
  # through is right rather than convenient -- the Launcher already drops
  # autorepeat itself, so holding a key behaves exactly as holding the D-pad.
  @impl GenServer
  def handle_info({:_input, {:key, {key, value, _mods}}, _raw, _id}, state) do
    press(key, value)
    {:noreply, state}
  end

  # Codepoints have no press/release, only "a character was typed", so they
  # are sent as a press. The Launcher only acts on presses anyway; the one
  # thing that needs releases is the power-off chord, which is on Escape and
  # therefore comes through :key.
  def handle_info({:_input, {:codepoint, {char, _mods}}, _raw, _id}, state) do
    case Map.fetch(@characters, String.downcase(char)) do
      {:ok, button} -> send_events([{:ev_key, button, 1}])
      :error -> :ok
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp press(@chord_key, 1) do
    send_events(Enum.map(@chord, &{:ev_key, &1, 1}))
  end

  defp press(key, value) do
    case Map.fetch(@named_keys, key) do
      {:ok, button} -> send_events([{:ev_key, button, value}])
      :error -> :ok
    end
  end

  defp send_events(events) do
    if pid = Process.whereis(Launcher) do
      send(pid, {:input_event, "(MayonnaiOS.Keyboard)", events})
    end
  end

  defp viewport_name do
    get_in(Application.get_env(:mayonnaios, :viewport), [:name]) || :main_viewport
  end
end
