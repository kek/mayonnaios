defmodule MayonnaiOS.Moonlight.App do
  @moduledoc """
  The System menu's "Moonlight settings" row: the rows of
  `MayonnaiOS.Moonlight`'s config file, edited with the pad.

  An app rather than a program, on the same terms as `MayonnaiOS.Update.App`:
  a module in this firmware, started in this VM, with a scene of its own and
  no external process handed the screen. It needs no hardware, so unlike the
  two Bluetooth apps nothing stops a second one -- there is one process
  because there is one screen.

  ## The buttons

      up / down       move between the rows
      left / right    change a choice row's value
      A               open a text row's editor, or save on the last row
      A while editing keep what was typed and close the editor
      Y while editing remove the character under the caret
      B / Menu        leave, which is the launcher's own and not this app's

  While the editor is open the D-pad belongs to it -- left and right move the
  caret, up and down change the character under it -- which is the same
  arrangement, and the same character picker, as the file browser's rename
  editor. A handheld has no text input, so a picker is what there is; see
  `MayonnaiOS.Browser` for the argument.

  ## Nothing is written until the Save row

  Every other change is in memory, and the panel says "unsaved changes" while
  any of them differ from what is on the disk. Two reasons for an explicit
  save rather than a write per change. A `moonlight.conf` lives on the data
  partition, and writing it on every press of right would put four writes on
  the flash for one decision about the bitrate. And a write can fail --
  a read-only filesystem, a full one -- which needs somewhere to say so; a
  row that reports its own outcome is that somewhere.

  The cost is the obvious one: Menu leaves without asking, and unsaved changes
  go with it. That is why the header carries them rather than a footnote.

  ## Leaving does not stop a stream

  Moonlight reads its config when it starts. Changing a value here while a
  stream is running changes the next stream, not this one -- and the launcher
  cannot have both on the screen at once anyway, since a running program owns
  the panel. The footer says so, because "I turned the bitrate down and
  nothing happened" is otherwise a reasonable thing to conclude.
  """

  use GenServer

  alias MayonnaiOS.Moonlight

  @sessions MayonnaiOS.Moonlight.App.Sessions

  # The launcher's vocabulary, in which the atom named "b" is the button
  # printed A on this board's shell -- see `MayonnaiOS.Launcher`'s moduledoc
  # for the device tree's account of that.
  @accept :btn_b
  @remove :btn_x
  @menu :btn_mode
  @up :btn_dpad_up
  @down :btn_dpad_down
  @left :btn_dpad_left
  @right :btn_dpad_right

  # What the address and app rows can type. Digits and a dot first, because
  # the field that is empty on a new device is the host address and the
  # character it most often starts with is a digit; letters follow for the
  # host that has a name, and for "Desktop".
  @alphabet String.graphemes(
              "0123456789." <>
                "abcdefghijklmnopqrstuvwxyz" <>
                "ABCDEFGHIJKLMNOPQRSTUVWXYZ" <> "-_ "
            )

  # -- the app protocol the Launcher uses --------------------------------------

  @doc """
  Start the app. Idempotent: opening the row again while it is already running
  shows the same process rather than starting a second one.
  """
  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts \\ []) do
    case DynamicSupervisor.start_child(@sessions, {__MODULE__, opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Stop the app."
  @spec stop() :: :ok
  def stop do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(@sessions, pid)
    end
  end

  @doc """
  Forward an evdev report from the Launcher.

  A cast, for the same reason `MayonnaiOS.Update.App.input/1` is: nothing here
  may make a button press wait on this process.
  """
  @spec input([tuple()]) :: :ok
  def input(events) do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, {:input, events}), else: :ok
  end

  @doc "The scene the launcher shows while this app has the buttons."
  @spec scene() :: module()
  def scene, do: MayonnaiOS.Scene.Moonlight

  @doc """
  Be told when the state changes, as `{:moonlight_app, snapshot}`.

  The same arrangement as `MayonnaiOS.Update.App.watch/1`: the scene calls
  this instead of polling, and the watcher is monitored so a scene torn down
  by `set_root/3` drops itself.
  """
  @spec watch(pid()) :: map() | :stopped
  def watch(pid) do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, {:watch, pid}), else: :stopped
  end

  @doc "Everything the panel needs, as one map. `:stopped` if the app is not running."
  @spec snapshot() :: map() | :stopped
  def snapshot do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :snapshot), else: :stopped
  end

  @doc "The DynamicSupervisor the app runs under, for the application tree."
  @spec sessions() :: Supervisor.child_spec()
  def sessions do
    %{
      id: @sessions,
      start: {DynamicSupervisor, :start_link, [[name: @sessions, strategy: :one_for_one]]},
      type: :supervisor
    }
  end

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      # Temporary, like the other app sessions: whatever went wrong is in the
      # log, and a restart would land on a screen the user already left.
      restart: :temporary
    }
  end

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The rows, which are the config's fields plus the one that writes them.

  Public because the scene draws them and the tests count them, and neither
  should have its own idea of how many there are.
  """
  @spec rows() :: [map()]
  def rows do
    Moonlight.fields() ++
      [
        %{
          id: :save,
          label: "Save",
          kind: :action,
          choices: [],
          suffix: "",
          placeholder: "",
          note: ""
        }
      ]
  end

  # -- state --------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    {settings, source} = Moonlight.load()

    {:ok,
     %{
       settings: settings,
       # What is on the disk, or what would be if nothing were changed. The
       # difference between this and `settings` is the whole of "unsaved".
       saved: settings,
       source: source,
       installed?: Moonlight.installed?(),
       path: Moonlight.config_path(),
       cursor: 0,
       editor: nil,
       message: nil,
       watchers: []
     }}
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state), do: {:reply, snapshot_of(state), state}

  def handle_call({:watch, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, snapshot_of(state), %{state | watchers: [pid | state.watchers]}}
  end

  @impl GenServer
  def handle_cast({:input, events}, state) do
    {:noreply, state |> apply_events(events) |> notify(state)}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | watchers: List.delete(state.watchers, pid)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- input ------------------------------------------------------------------

  defp apply_events(state, events) do
    Enum.reduce(events, state, fn
      {:ev_key, key, 1}, acc -> press(acc, key)
      _event, acc -> acc
    end)
  end

  # Menu is the launcher's; it stops this app before this process would see
  # the press at all. Dropped here anyway so that a keyboard, a test or a
  # future caller cannot make it mean something else by accident.
  defp press(state, @menu), do: state

  # -- while the editor is open, the D-pad is the editor's --

  defp press(%{editor: editor} = state, key) when editor != nil do
    case key do
      @left -> %{state | editor: move_caret(editor, -1)}
      @right -> %{state | editor: move_caret(editor, +1)}
      @up -> %{state | editor: step_char(editor, -1)}
      @down -> %{state | editor: step_char(editor, +1)}
      @remove -> %{state | editor: drop_char(editor)}
      @accept -> accept(state, editor)
      _other -> state
    end
  end

  # -- the row list --

  defp press(state, @up), do: move(state, -1)
  defp press(state, @down), do: move(state, +1)
  defp press(state, @left), do: change(state, -1)
  defp press(state, @right), do: change(state, +1)
  defp press(state, @accept), do: open(state)
  defp press(state, _key), do: state

  defp move(state, delta) do
    count = length(rows())
    cursor = Integer.mod(state.cursor + delta, count)
    %{state | cursor: cursor, message: nil}
  end

  # Left and right on a text row do nothing: there is no next address, and a
  # direction that silently means nothing on some rows and something on others
  # is better than one that opens an editor nobody asked for.
  defp change(state, delta) do
    case current_row(state) do
      %{kind: :choice} = field ->
        %{state | settings: Moonlight.step(field, state.settings, delta), message: nil}

      _other ->
        state
    end
  end

  defp open(state) do
    case current_row(state) do
      %{kind: :text, id: id} ->
        chars = state.settings |> Map.get(id, "") |> String.graphemes()
        # The caret starts at the end: the common edit to an address that is
        # already there is to change its last digits, and the common edit to
        # an empty one is to type it, which is also the end.
        %{state | editor: %{id: id, chars: chars, caret: length(chars)}, message: nil}

      %{kind: :action, id: :save} ->
        save(state)

      _other ->
        state
    end
  end

  defp save(state) do
    case Moonlight.save(state.settings) do
      {:ok, path} ->
        %{
          state
          | saved: state.settings,
            source: :file,
            path: path,
            message: {:ok, "Saved to #{path}"}
        }

      {:error, reason} ->
        %{state | message: {:error, "Could not write #{state.path}: #{why(reason)}"}}
    end
  end

  defp accept(state, %{id: id, chars: chars}) do
    %{state | settings: Map.put(state.settings, id, Enum.join(chars)), editor: nil}
  end

  defp current_row(state), do: Enum.at(rows(), state.cursor)

  # -- the character picker ------------------------------------------------------
  #
  # The same three operations as `MayonnaiOS.Browser`'s rename editor, on the
  # same terms: the caret can sit one past the end, where up or down puts a
  # character there rather than doing nothing.

  defp move_caret(%{chars: chars, caret: caret} = editor, delta) do
    %{editor | caret: caret |> Kernel.+(delta) |> max(0) |> min(length(chars))}
  end

  defp step_char(%{chars: chars, caret: caret} = editor, delta) do
    if caret >= length(chars) do
      %{editor | chars: chars ++ [next_char(nil, delta)]}
    else
      current = Enum.at(chars, caret)
      %{editor | chars: List.replace_at(chars, caret, next_char(current, delta))}
    end
  end

  # A character the picker does not know -- one a hand-edited file put in the
  # address -- has no position to step from, so the first press replaces it
  # with the start of the alphabet rather than doing nothing at all.
  defp next_char(current, delta) do
    case Enum.find_index(@alphabet, &(&1 == current)) do
      nil -> hd(@alphabet)
      index -> Enum.at(@alphabet, Integer.mod(index + delta, length(@alphabet)))
    end
  end

  defp drop_char(%{chars: []} = editor), do: editor

  defp drop_char(%{chars: chars, caret: caret} = editor) do
    at = min(caret, length(chars) - 1)
    chars = List.delete_at(chars, at)
    %{editor | chars: chars, caret: min(at, length(chars))}
  end

  # -- snapshot -----------------------------------------------------------------

  defp snapshot_of(state) do
    %{
      settings: state.settings,
      source: state.source,
      installed?: state.installed?,
      path: state.path,
      cursor: state.cursor,
      editor: state.editor,
      message: state.message,
      unsaved?: state.settings != state.saved
    }
  end

  defp notify(state, previous) do
    if previous != nil and snapshot_of(state) == snapshot_of(previous) do
      state
    else
      snapshot = snapshot_of(state)
      Enum.each(state.watchers, &send(&1, {:moonlight_app, snapshot}))
      state
    end
  end

  # The words for a write that did not happen. `MayonnaiOS.Browser.why/1`
  # already has this vocabulary and this reuses it, so the panel and the ring
  # log say the same thing about the same errno.
  defp why(reason), do: MayonnaiOS.Browser.why(reason)
end
