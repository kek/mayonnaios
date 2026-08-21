defmodule MayonnaiOS.Launcher do
  @moduledoc """
  Runs an external program on a button press and stops it on another.

  This is the games-appliance mechanic in miniature: the Elixir UI hands the
  screen to another process, that process draws on the GPU, and the UI takes
  the screen back when it exits. kmscube stands in for an emulator here.

  ## Which button is which

  The physical A button is **not** `:btn_a`. Linux defines `BTN_A == BTN_SOUTH
  == 0x130` and `BTN_B == BTN_EAST == 0x131`, and InputEvent decodes by code,
  so its `:btn_a` means "south". This board follows the Nintendo layout, and
  its device tree puts A on the east position:

      Action-Pad A    305   BTN_EAST     -> InputEvent :btn_b
      Action-Pad B    304   BTN_SOUTH    -> InputEvent :btn_a
      Key Start       315   BTN_START    -> InputEvent :btn_start

  Read back from `/sys/firmware/devicetree/base/gpio-keys-gamepad/*/label`
  and `linux,code` on the device, not inferred. Binding `:btn_a` for "A" would
  silently bind the B button, and nothing about the failure would say so.

  ## Giving the screen back

  Scenic only writes `/dev/fb0` when its graph changes, so after the external
  program exits the panel still shows whatever that program left there. The
  viewport has to be told to repaint; `Scenic.ViewPort.set_root/3` does it.

  ## The full set of bindings

      D-pad up/down move the menu cursor
      A             launch the selected program
      Menu          go back to the home screen
      X             switch between the menu and diagnostics
      Select+Menu   power off

  These are the buttons as printed on the shell. Two of the atoms above name
  the opposite button; see the note on the attributes below.

  Menu is the one way back. It stops a running program if there is one and
  otherwise leaves diagnostics, so the same press always means the same thing
  -- "put me back where I started" -- rather than depending on what is
  currently on the panel. Start used to do the stopping, which split "get out
  of this" across two keys depending on which kind of thing you were in.

  Select+Menu still powers off, so the chord is checked before the plain
  press. Power off is a chord rather than a button because it is not undoable
  and this is a handheld that gets carried in a pocket.

  This process owns `event0`, so everything on the gamepad is bound here even
  when it belongs to something else. `MayonnaiOS.Diagnostics` owns the
  other two input devices for the same reason in reverse.

  ## Where the menu lives, and why the cursor is here

  The list of programs comes from `MayonnaiOS.Programs`, which reads
  `config :mayonnaios, :programs`. The *cursor* -- which entry is
  selected -- is state in this process rather than in the scene, for two
  reasons that are both about how this device is put together.

  First, the cairo-fb driver delivers no input. The gamepad reaches Elixir
  only through `InputEvent` on `event0`, which this process opens, so a
  Scenic scene on this hardware can never receive a D-pad press at all.

  Second, `Scenic.ViewPort.set_root/3` stops the running scene and starts a
  fresh one. This module calls it after every program exit (that is how the
  panel gets repainted), so a selection held in the scene would reset to the
  top every time someone came back from a game -- the one moment it most
  obviously should not.

  So the cursor is pushed *into* the scene as the `set_root/3` argument, and
  the scene renders it. The scene reads the program list itself.
  """

  use GenServer
  require Logger

  alias MayonnaiOS.Programs

  @device "/dev/input/event0"

  # See the moduledoc: this is physical A, not the atom's name.
  @launch_button :btn_b

  # X and Y are swapped too, and the device tree does not admit it.
  #
  # The first version of this file said X and Y needed no translation: the DT
  # labels "Action-Pad X" 307 and "Action Pad Y" 308, and Linux has
  # BTN_X == BTN_NORTH == 307 and BTN_Y == BTN_WEST == 308, so the labels
  # looked self-consistent. Pressing the buttons says otherwise. The button
  # silkscreened X emits 308 and the one silkscreened Y emits 307 -- the DT's
  # X/Y labels are the wrong way round for this board's shell.
  #
  # So :btn_y below really is the X button. Reading the device tree was not
  # enough here, which is the same lesson as A and B and was available the
  # whole time; it just was not applied twice.
  #
  # Y (:btn_x) is deliberately unbound. It played the audio test while audio
  # was the open question on this board; that is answered, and a key on a
  # handheld that makes a noise when pressed by accident is not worth keeping
  # for a check that belongs in IEx. `MayonnaiOS.Audio.run/0` still does it.
  @diagnostics_button :btn_y

  # Menu, doing double duty: alone it is the way back to the home screen,
  # and held with Select it powers off. The chord is tested first.
  @poweroff_modifier :btn_select
  @home_button :btn_mode

  # The D-pad. Codes 544-547 are BTN_DPAD_UP..RIGHT, and InputEvent decodes
  # them to these atoms (deps/input_event types table). Unlike the face
  # buttons there is no name collision to fall into here -- but the codes came
  # off this board's device tree, which has already lied once about X and Y,
  # so the catch-all `press/2` logs unhandled keys at debug: if up and down
  # turn out to be swapped, `log_attach_all(:debug)` on the device says so
  # immediately instead of leaving a menu that scrolls the wrong way.
  @up_button :btn_dpad_up
  @down_button :btn_dpad_down

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Whether the external program is running right now.
  """
  def running?, do: GenServer.call(__MODULE__, :running?)

  @doc """
  The OS pid of the running program, or `nil`.

  `MayonnaiOS.Diagnostics` uses this to read GPU busy time out of that
  process's `fdinfo`. Scanning every process for a panfrost fd would cost
  thousands of procfs reads a second on this SoC, and it is unnecessary:
  Scenic renders on the CPU through cairo, so the program launched here is
  the only GPU client there is.
  """
  def os_pid, do: GenServer.call(__MODULE__, :os_pid)

  @doc """
  Start or stop it from a console, without pressing anything.
  """
  def launch, do: GenServer.call(__MODULE__, :launch)
  def stop_program, do: GenServer.call(__MODULE__, :stop)

  @doc """
  The index of the highlighted menu entry.

  Exposed so a console -- or a test that has just injected a synthetic D-pad
  event -- can read the cursor without looking at the panel. There is
  deliberately no setter: the only way to move it is the binding the user has,
  which is the part worth testing.
  """
  def selected, do: GenServer.call(__MODULE__, :selected)

  @impl GenServer
  def init(opts) do
    device = Keyword.get(opts, :device, @device)

    case open_device(device) do
      {:ok, _pid} ->
        Logger.info("[launcher] watching #{device}: D-pad moves, A launches, Start stops")
        {:ok, new_state()}

      {:error, reason} ->
        # No buttons is not a reason to fail the boot -- the UI is still
        # useful, and this is the only thing that would be lost.
        Logger.warning("[launcher] #{device} unavailable: #{inspect(reason)}")
        {:ok, new_state()}
    end
  end

  # Check for the node before opening it, because InputEvent does not fail the
  # way the clause above expects on every machine. Its port binary is only
  # built on Linux (its Makefile skips the C build elsewhere), so on a macOS
  # host `InputEvent.start_link/1` *raises* inside a linked start -- which
  # would take this process down at boot rather than degrade to "no buttons".
  # With the guard the Launcher starts anywhere, which is what lets the tests
  # send it synthetic key events.
  defp open_device(device) do
    if File.exists?(device), do: InputEvent.start_link(device), else: {:error, :enoent}
  end

  defp new_state,
    do: %{
      port: nil,
      app: nil,
      app_error: nil,
      running: nil,
      held: MapSet.new(),
      scene: :home,
      selected: 0
    }

  @impl GenServer
  def handle_call(:running?, _from, state), do: {:reply, state.port != nil, state}

  def handle_call(:os_pid, _from, %{port: nil} = state), do: {:reply, nil, state}

  def handle_call(:os_pid, _from, state) do
    case Port.info(state.port, :os_pid) do
      {:os_pid, pid} -> {:reply, pid, state}
      _ -> {:reply, nil, state}
    end
  end

  def handle_call(:launch, _from, state), do: {:reply, :ok, do_launch(state)}
  def handle_call(:stop, _from, state), do: {:reply, :ok, do_stop(state)}
  def handle_call(:selected, _from, state), do: {:reply, state.selected, state}

  @impl GenServer
  # An app has the buttons: the launcher's own bindings are off and every
  # event is forwarded, Menu included. The app is free to ignore what it does
  # not want -- `MayonnaiOS.Controller.Report` drops Menu on the floor -- and
  # the only thing handled here is the way out.
  #
  # This is the rule the launcher already applies to an external program:
  # whatever has the screen has the input, and Menu is the way back. The
  # difference is only in the plumbing. A program reads evdev for itself
  # through udev, so the launcher has nothing to forward; an app runs in this
  # VM and has to be handed the reports, because this process is the one
  # holding `event0` open and evdev is not a broadcast.
  #
  # Whole reports go across rather than single events, so a diagonal or a
  # button and a direction pressed in the same kernel report reach the app as
  # one thing and become one HID report.
  def handle_info({:input_event, _device, events}, %{app: app} = state) when app != nil do
    state =
      Enum.reduce(events, state, fn
        {:ev_key, key, 1}, acc -> hold(acc, key)
        {:ev_key, key, 0}, acc -> release(acc, key)
        _, acc -> acc
      end)

    app.input(events)

    {:noreply, leave_app(state, events)}
  end

  def handle_info({:input_event, _device, events}, state) do
    state =
      Enum.reduce(events, state, fn
        # value 1 is press and 0 is release; 2 is autorepeat and is ignored.
        # Releases matter now: the power-off chord needs to know what is held.
        #
        # Dropping autorepeat means the D-pad does not scroll when held: one
        # press, one row. That is a simplification, not an oversight -- each
        # move re-roots the viewport, and holding down would queue a scene
        # restart per repeat. Worth revisiting only if the list grows long.
        {:ev_key, key, 1}, acc -> acc |> hold(key) |> press(key)
        {:ev_key, key, 0}, acc -> release(acc, key)
        _, acc -> acc
      end)

    {:noreply, state}
  end

  # The program exited on its own. Name it from `running` rather than from the
  # cursor: the cursor may well have moved while the program had the screen,
  # and a log line that names the wrong binary is worse than none.
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.info("[launcher] #{name_of(state.running)} exited (#{status})")
    repaint(state)
    {:noreply, %{state | port: nil, running: nil}}
  end

  # Log what the program says, rather than dropping it.
  #
  # This used to discard the data outright, and it cost an evening. RetroArch
  # started, rendered one frame and exited, and the entire visible evidence was
  # "a quick flash on the screen and nothing" -- while the program had been
  # printing the exact reason to the pipe the whole time:
  #
  #     [ERROR] [Video] Cannot initialize input driver. Exiting...
  #
  # An external program that dies on this device has no other way to tell
  # anyone why: there is no console, the screen belongs to whatever ran last,
  # and the ring logger is the only thing anybody can read afterwards.
  #
  # Trimmed and length-capped because a chatty program should not be able to
  # push everything else out of a fixed-size ring buffer.
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    data
    |> String.split("\n", trim: true)
    |> Enum.each(fn line ->
      Logger.info("[#{program_name(state)}] #{String.slice(line, 0, 300)}")
    end)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # The running program's name, for log lines. Falls back to "program" rather
  # than crashing the log call if a message arrives after the state is cleared.
  defp program_name(%{running: %{name: name}}), do: name
  defp program_name(_), do: "program"

  defp hold(state, key), do: %{state | held: MapSet.put(state.held, key)}
  defp release(state, key), do: %{state | held: MapSet.delete(state.held, key)}

  # Menu while an app is running. The power-off chord is checked first, for
  # the same reason it is checked first everywhere else: a bare Menu must
  # never be able to switch the device off, and someone holding Select while
  # using the controller is holding Select on purpose.
  defp leave_app(state, events) do
    if Enum.any?(events, &match?({:ev_key, @home_button, 1}, &1)) do
      if MapSet.member?(state.held, @poweroff_modifier) do
        poweroff()
        state
      else
        state |> stop_app() |> go_home()
      end
    else
      state
    end
  end

  defp stop_app(%{app: nil} = state), do: state

  defp stop_app(%{app: app} = state) do
    app.stop()
    Logger.info("[launcher] stopped #{name_of(state.running)}")
    %{state | app: nil, running: nil}
  end

  defp press(state, @launch_button), do: do_launch(state)
  defp press(state, @diagnostics_button), do: toggle_scene(state)
  defp press(state, @up_button), do: move(state, -1)
  defp press(state, @down_button), do: move(state, +1)

  # Menu: back to the home screen, or -- with Select held -- power off.
  #
  # The chord is checked first, so the modifier is not decorative: a bare
  # Menu must never be able to shut the device down, because it is the key
  # someone reaches for to get out of a game.
  defp press(state, @home_button) do
    if MapSet.member?(state.held, @poweroff_modifier) do
      poweroff()
      state
    else
      go_home(state)
    end
  end

  defp press(state, key) do
    # Debug, not info: this fires for every unbound button on the pad. It
    # exists because the D-pad codes are inherited from the device tree and
    # this board's device tree has been wrong before -- if up and down feel
    # swapped, this is the line that says which atom the hardware really sent.
    Logger.debug("[launcher] unhandled key #{inspect(key)}")
    state
  end

  # Move the menu cursor. The list is re-read here rather than kept in state:
  # it is deterministic, cheap, and there is then no way for the cursor to be
  # bounded by a stale length.
  defp move(state, delta) do
    programs = Programs.list()
    moved = Programs.step(programs, state.selected, delta)

    # Repaint only when the menu is actually the thing on screen. While an
    # external program is running it owns KMS, and pushing the viewport would
    # write the menu into /dev/fb0 underneath its output -- visible as the
    # menu bleeding through a game. On the diagnostics screen the cursor is
    # not drawn at all, so a repaint there would be pure cost. The cursor
    # still moves in both cases; only the redraw waits.
    #
    # And only when the cursor actually moved. `set_root/3` is not a redraw:
    # it stops the running scene process and starts a new one. At the ends of
    # the list -- and with the single-entry list this ships with, on every
    # press -- `step/3` returns the index it was given, so without this guard
    # holding down a direction would tear down and rebuild the scene at the
    # repeat rate for no visible change.
    if moved != state.selected and state.port == nil and state.scene == :home do
      show(:home, %{state | selected: moved})
    end

    %{state | selected: moved}
  end

  # Back to the menu, from wherever we are.
  #
  # `scene` is set before `do_stop/1` rather than after, because do_stop
  # repaints whatever `scene` says: setting it first makes one viewport push
  # do both jobs. Pushing twice would be visible -- diagnostics for a frame,
  # then the menu.
  defp go_home(state) do
    home = %{state | scene: :home}

    cond do
      state.port != nil ->
        do_stop(home)

      state.scene != :home ->
        show(:home, home)
        home

      # Already home with nothing running. Deliberately not a repaint: this is
      # the button people press when unsure, and `set_root/3` tears the scene
      # down and builds a new one, so answering an idle press with a rebuild
      # would make the panel flicker for no reason.
      true ->
        state
    end
  end

  # Flip between the menu and the diagnostics readout. The readout is
  # what makes the physical checks -- charger, volume keys, headphone jack --
  # answerable by looking at the device instead of over SSH.
  defp toggle_scene(state) do
    next = if state.scene == :home, do: :diagnostics, else: :home
    show(next, state)
    %{state | scene: next}
  end

  defp poweroff do
    Logger.info("[launcher] Select+Menu: powering off")

    # Whether poweroff/0 brings this board down cleanly is the genuinely
    # unknown part. The PMIC power key is not wired into Linux here
    # (CONFIG_INPUT_AXP20X_PEK is unset and there is no power-key node), so
    # this is the only orderly shutdown the device has.
    Nerves.Runtime.poweroff()
  end

  # Three outcomes, logged apart from each other on purpose. "Nothing
  # configured" and "configured but not in the image" are different bugs in
  # different files, and a single "could not launch" would hide which.
  defp do_launch(%{port: nil, app: nil} = state) do
    programs = Programs.list()
    start_program(Programs.at(programs, state.selected), state)
  end

  defp do_launch(state) do
    Logger.info("[launcher] already running")
    state
  end

  defp start_program(nil, state) do
    Logger.warning("[launcher] no programs configured (config :mayonnaios, :programs)")
    state
  end

  defp start_program(%{installed?: false} = program, state) do
    Logger.warning("[launcher] #{program.path} not installed")
    state
  end

  # An app: no port, no external process, no screen to hand over. It starts
  # here in this VM and the panel switches to whatever scene it names.
  #
  # A failure to start is put on the panel rather than only in the log. The
  # reasons are Bluetooth bind errors -- `:eusers`, `:enodev` -- and they are
  # exactly the kind of thing that is diagnosable in one glance and
  # impenetrable without one. The scene is shown either way, and the error
  # travels to it as the scene's start argument, the same route the home
  # scene's cursor takes.
  defp start_program(%{app: module} = program, state) when is_atom(module) and module != nil do
    Logger.info("[launcher] starting #{program.name}")

    state =
      case module.start() do
        {:ok, _pid} ->
          %{state | app: module, running: program, app_error: nil}

        {:error, {:already_started, _pid}} ->
          %{state | app: module, running: program, app_error: nil}

        {:error, reason} ->
          Logger.warning("[launcher] #{program.name} would not start: #{inspect(reason)}")
          %{state | app: nil, running: nil, app_error: reason}
      end

    state = %{state | scene: {:app, module}}
    repaint(state)
    state
  end

  defp start_program(program, state) do
    Logger.info("[launcher] launching #{Enum.join([program.path | program.args], " ")}")

    # Programs that read input through udev need the daemon running and the
    # input devices in its database first. Nothing in this application does --
    # InputEvent reads evdev directly -- but RetroArch has no other way to see
    # a gamepad, and without this it renders a frame and exits with "Cannot
    # initialize input driver".
    #
    # Opt-in per program rather than always, because it is a daemon start for
    # the benefit of one kind of program, and because a launcher that silently
    # starts services is harder to reason about than one that is told to.
    if Map.get(program, :needs_udev, false) do
      case MayonnaiOS.Udev.ensure_started() do
        :ok -> :ok
        {:error, reason} -> Logger.warning("[launcher] udev unavailable: #{inspect(reason)}")
      end
    end

    # Port.open raises rather than returning an error, and `installed?` is only
    # File.exists?/1 -- so a configured path that is a directory, or a file
    # without the execute bit, reaches here looking launchable and then throws
    # :eacces or :enoent. This runs inside handle_info, so an uncaught raise
    # takes the Launcher down and with it the only route to the buttons: the
    # device would stop responding to the gamepad entirely because one menu
    # entry was misconfigured.
    try do
      port =
        Port.open({:spawn_executable, String.to_charlist(program.path)}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          # :spawn_executable does not go through a shell and does not search
          # $PATH, so argv is passed explicitly and paths must be absolute.
          args: program.args
        ])

      %{state | port: port, running: program}
    rescue
      e ->
        Logger.warning("[launcher] #{program.path} would not start: #{Exception.message(e)}")
        state
    end
  end

  defp do_stop(%{port: nil} = state), do: state

  defp do_stop(%{port: port} = state) do
    # Closing the port shuts the pipes but does not reliably stop a program
    # that never reads stdin, and kmscube does not. Signal the OS process.
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> System.cmd("kill", ["-TERM", Integer.to_string(os_pid)])
      _ -> :ok
    end

    _ = try do: Port.close(port), rescue: (_ -> :ok)

    Logger.info("[launcher] stopped #{name_of(state.running)}")
    repaint(state)
    %{state | port: nil, running: nil}
  end

  defp name_of(%{name: name}), do: name
  defp name_of(_), do: "program"

  # Scenic redraws on change, so the panel keeps the external program's last
  # frame until the viewport is pushed again. Coming back from kmscube has to
  # return to whichever scene was showing, not always the home one -- watching
  # the GPU temperature climb means being on diagnostics before and after.
  defp repaint(%{scene: scene} = state), do: show(scene, state)

  defp show(:diagnostics, _state), do: set_root(MayonnaiOS.Scene.Diagnostics, nil)

  # An app names its own scene, so the launcher does not have to know about
  # any of them. The start argument carries why it did not start, which is nil
  # in the ordinary case.
  defp show({:app, module}, state), do: set_root(module.scene(), %{error: state.app_error})

  # The cursor travels as the scene's start argument. Deliberately only the
  # index: the scene calls `Programs.list/0` itself, so no list is copied into
  # a scene start on every keypress, and the two cannot disagree about order
  # because both derive from the same config.
  defp show(_home, state), do: set_root(default_scene(), %{selected: state.selected})

  defp set_root(nil, _param), do: :ok

  # Repainting must never take the Launcher down when there is no UI running.
  # Scenic.ViewPort.info/1 is a bare GenServer.call, so on a missing viewport
  # it *exits* rather than returning an error -- the `case` this used to do
  # could not catch that, and the clause that looked like it handled it was
  # unreachable. It went unnoticed because the host had no :viewport config,
  # so default_scene/0 returned nil and this function short-circuited above
  # before ever asking Scenic anything.
  #
  # That matters beyond the tests: Scenic is deliberately not started at boot
  # (see MayonnaiOS), so on a device where start_ui/0 has not been called yet,
  # one button press would have crashed the process that owns the buttons.
  defp set_root(scene, param) do
    with pid when is_pid(pid) <- Process.whereis(viewport_name()),
         {:ok, vp} <- Scenic.ViewPort.info(pid) do
      Scenic.ViewPort.set_root(vp, scene, param)
    else
      _ -> :ok
    end
  end

  defp viewport_name do
    get_in(Application.get_env(:mayonnaios, :viewport), [:name]) || :main_viewport
  end

  defp default_scene do
    get_in(Application.get_env(:mayonnaios, :viewport), [:default_scene])
  end
end
