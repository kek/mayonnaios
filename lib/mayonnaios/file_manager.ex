defmodule MayonnaiOS.FileManager do
  @moduledoc """
  The file manager app: what is on the writable card, and what can be done to
  it, with a D-pad and four buttons.

  An app rather than a program -- a module in this firmware, started in this
  VM, with no external process and no screen handed over. See
  `MayonnaiOS.Programs` for what that distinction costs and buys, and
  `MayonnaiOS.Controller` for the other one.

      iex> MayonnaiOS.FileManager.start()
      iex> MayonnaiOS.FileManager.snapshot().view
      :places
      iex> MayonnaiOS.FileManager.stop()

  This process holds the cursor and the pending operation.
  `MayonnaiOS.Files` holds the boundary -- every path this app touches is
  built there from a root key and a list of checked names, and nothing here
  ever assembles one. `MayonnaiOS.Scene.FileManager` draws what
  `snapshot/0` returns.

  ## The buttons are the ones that already exist

      D-pad up/down   move the cursor
      D-pad left/right one screen at a time
      A               open -- a directory, or the actions for a file
      B               back -- up a directory, or out of a sheet
      Y               the second verb, and the screen says what it is
      Menu            leave, handled by the Launcher

  No chords. Nothing on X, which is the diagnostics key everywhere else, and
  nothing on Select, which is the power-off modifier. Y was unbound and is now
  the second verb: actions while browsing, "delete this" on the confirmation,
  "remove this character" in the rename editor. What it means is written on the
  panel in every view, because a button whose meaning changes and is not
  labelled is a button nobody presses twice.

  Autorepeat (evdev value 2) moves the cursor and is ignored for the action
  buttons, so holding a direction scrolls and holding A does not fire twice.
  Whether this board's gpio-keys emits autorepeat at all has not been checked,
  which is why left and right page by a screen: paging works whether or not
  the kernel repeats, and a directory with two hundred ROMs in it needs one of
  the two.

  ## Deleting takes two presses, on two different buttons

  Choosing Delete opens a confirmation naming the full path, and the
  confirmation is not answered by the button that opened it. A ran the action;
  **Y** does the delete, and A -- like B, like any direction -- cancels it.

  That is the whole reason the confirmation exists. A device that is switched
  off by pulling its power has no undo, no trash and no journal to replay, so
  a second press of the same button is not a confirmation, it is a
  double-press waiting to happen.

  `MayonnaiOS.Files.delete/1` will not remove a directory that has anything in
  it, so nothing here can lose more than the one name on the screen.

  ## Copy and move are a clipboard, because there is no keyboard

  Choosing Copy or Move remembers the entry. Walk to another directory, press
  Y, and the first action on the sheet is to paste it there. Nothing
  overwrites: an existing destination is refused rather than replaced. A move
  clears the clipboard because the source is gone; a copy keeps it, so the
  same ROM can be put on both cards, and "Forget" clears it.

  Renaming needs text, and this handheld has no text input, so the rename
  editor is a character picker: left and right move the caret, up and down
  change the character under it, Y removes it. It is slow and it is real -- the
  alternative was a rename verb that could not be reached from the device.
  """

  use GenServer

  alias MayonnaiOS.Files

  # The buttons as InputEvent names them, which is not what the shell prints.
  # `MayonnaiOS.Launcher` has the full account: the device tree lies about A/B
  # and about X/Y, and this board's shell A is BTN_EAST (:btn_b) while shell Y
  # is 307 (:btn_x). Getting these wrong is not a crash, it is a device where
  # the wrong button deletes something, so they are named once and only here.
  @a_button :btn_b
  @b_button :btn_a
  @y_button :btn_x

  @up :btn_dpad_up
  @down :btn_dpad_down
  @left :btn_dpad_left
  @right :btn_dpad_right

  @dpad [@up, @down, @left, @right]

  # Menu belongs to the Launcher: it is the way out of any app, and this one
  # drops it on the floor exactly as MayonnaiOS.Controller.Report does.
  @menu :btn_mode

  # One screen. The scene shows twelve rows; ten keeps two rows of context
  # across a page, which is the difference between paging and teleporting.
  @page 10

  # What the rename editor can type. Not every character a filesystem accepts
  # -- a picker with a thousand entries is not a picker -- but every character
  # a ROM, a save or a directory on this device actually uses.
  @alphabet String.graphemes(
              "abcdefghijklmnopqrstuvwxyz" <>
                "ABCDEFGHIJKLMNOPQRSTUVWXYZ" <>
                "0123456789" <> ".-_ ()[]&'!+,"
            )

  # -- the app protocol the Launcher uses -------------------------------------

  @sessions MayonnaiOS.FileManager.Sessions

  @doc """
  Start the app.

  Under a DynamicSupervisor rather than linked to the caller, which is how
  `MayonnaiOS.Controller` starts too. `MayonnaiOS.Launcher` calls this from
  inside the process that owns `event0`, so a link would mean that a bug in
  here -- a directory that turns into something odd halfway through a listing,
  say -- takes the launcher down with it, and the device then stops answering
  its buttons at all.

  Named, so `stop/0` and `input/1` need no pid.
  """
  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts \\ []) do
    case DynamicSupervisor.start_child(@sessions, {__MODULE__, opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:error, {:already_started, pid}}
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
      # Temporary for the same reason the controller session is: whatever went
      # wrong is in the log and on the panel, and a file manager that restarts
      # itself back onto the screen someone just left is not help.
      restart: :temporary
    }
  end

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Whether the app is running."
  @spec active?() :: boolean()
  def active?, do: Process.whereis(__MODULE__) != nil

  @doc """
  Forward an evdev report from the Launcher.

  A cast: this is called from the process holding `event0`, and a directory
  listing must never be able to make the buttons late. Safe when the app is
  not running, because the launcher's view of that and the actual state can
  differ for as long as it takes to stop.
  """
  @spec input([tuple()]) :: :ok
  def input(events) do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, {:input, events}), else: :ok
  end

  @doc "The scene the launcher shows while this app has the buttons."
  @spec scene() :: module()
  def scene, do: MayonnaiOS.Scene.FileManager

  @doc """
  Everything the panel needs, as one map.

  A call, so a test that has just cast a synthetic button press is ordered
  behind it and does not have to sleep.
  """
  @spec snapshot() :: map() | :stopped
  def snapshot do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :snapshot), else: :stopped
  end

  @doc """
  Be told when the snapshot changes, as `{:file_manager, snapshot}`.

  The scene does this instead of polling. A poll fast enough to feel like a
  button press is a `GenServer.call` every few frames forever; a push happens
  when something happened, which for a menu is only when a button is pressed.
  The watcher is monitored, so a scene torn down by `set_root/3` -- which
  happens on every repaint the launcher does -- drops itself.
  """
  @spec watch(pid()) :: map() | :stopped
  def watch(pid) do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, {:watch, pid}), else: :stopped
  end

  # -- state ------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    state = %{
      view: :places,
      places: Files.places(),
      place_cursor: 0,
      location: nil,
      dir: nil,
      entries: [],
      cursor: 0,
      space: nil,
      readable?: true,
      clipboard: nil,
      actions: [],
      action_cursor: 0,
      pending: nil,
      rename: nil,
      message: nil,
      watchers: []
    }

    state =
      case Keyword.get(opts, :open) do
        nil -> state
        key -> enter_place(state, key)
      end

    {:ok, state}
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

  defp snapshot_of(state), do: Map.delete(state, :watchers)

  defp notify(state, previous) do
    if state == previous do
      state
    else
      snapshot = snapshot_of(state)
      Enum.each(state.watchers, &send(&1, {:file_manager, snapshot}))
      state
    end
  end

  # -- input ------------------------------------------------------------------

  defp apply_events(state, events) do
    Enum.reduce(events, state, fn
      # A press, always.
      {:ev_key, key, 1}, acc -> press(acc, key)
      # Autorepeat, for the D-pad only: a held direction scrolls, a held A
      # does not launch an action over and over.
      {:ev_key, key, 2}, acc when key in @dpad -> press(acc, key)
      _event, acc -> acc
    end)
  end

  # Menu is the Launcher's, in every view. It must not be able to cancel a
  # confirmation or a rename either, because the launcher is going to act on
  # it regardless and two things happening on one press is one too many.
  defp press(state, @menu), do: state

  defp press(%{view: :places} = state, key) do
    count = length(state.places)

    case key do
      @up -> %{state | place_cursor: wrap(state.place_cursor - 1, count)}
      @down -> %{state | place_cursor: wrap(state.place_cursor + 1, count)}
      @left -> %{state | place_cursor: clamp(state.place_cursor - @page, count)}
      @right -> %{state | place_cursor: clamp(state.place_cursor + @page, count)}
      @a_button -> open_place(state)
      _other -> state
    end
  end

  defp press(%{view: :browse} = state, key) do
    count = length(state.entries)

    case key do
      @up -> %{state | cursor: wrap(state.cursor - 1, count)}
      @down -> %{state | cursor: wrap(state.cursor + 1, count)}
      @left -> %{state | cursor: clamp(state.cursor - @page, count)}
      @right -> %{state | cursor: clamp(state.cursor + @page, count)}
      @a_button -> open(state)
      @b_button -> back(state)
      @y_button -> open_actions(state)
      _other -> state
    end
  end

  defp press(%{view: :actions} = state, key) do
    count = length(state.actions)

    case key do
      @up -> %{state | action_cursor: wrap(state.action_cursor - 1, count)}
      @down -> %{state | action_cursor: wrap(state.action_cursor + 1, count)}
      @a_button -> run_action(state)
      @b_button -> %{state | view: :browse, actions: [], action_cursor: 0}
      _other -> state
    end
  end

  # The confirmation. Y deletes; everything else -- A included, deliberately
  # -- backs out. See the moduledoc.
  defp press(%{view: :confirm} = state, @y_button), do: confirm_delete(state)

  defp press(%{view: :confirm} = state, _key) do
    %{state | view: :browse, pending: nil, message: {:ok, "Nothing was deleted."}}
  end

  defp press(%{view: :rename} = state, key) do
    case key do
      @left -> %{state | rename: move_caret(state.rename, -1)}
      @right -> %{state | rename: move_caret(state.rename, +1)}
      @up -> %{state | rename: step_char(state.rename, -1)}
      @down -> %{state | rename: step_char(state.rename, +1)}
      @y_button -> %{state | rename: drop_char(state.rename)}
      @a_button -> confirm_rename(state)
      @b_button -> %{state | view: :browse, rename: nil, message: {:ok, "Rename cancelled."}}
      _other -> state
    end
  end

  defp press(state, _key), do: state

  # Wrapping for a single step, the way the launcher menu wraps: with the
  # cursor at the bottom of a listing, the top is one press away.
  defp wrap(_index, 0), do: 0
  defp wrap(index, count), do: Integer.mod(index, count)

  # Clamping for a page jump. A page that wrapped would mean pressing right
  # near the end of a long directory and landing back at the top, which reads
  # as the app having lost its place.
  defp clamp(_index, 0), do: 0
  defp clamp(index, count), do: index |> max(0) |> min(count - 1)

  # -- navigation -------------------------------------------------------------

  defp open_place(state) do
    case Enum.at(state.places, state.place_cursor) do
      nil -> state
      place -> enter_place(state, place.key)
    end
  end

  defp enter_place(state, key) do
    case Files.at(key) do
      {:ok, location} -> load(%{state | view: :browse}, location)
      {:error, reason} -> %{state | message: {:error, "#{key}: #{why(reason)}"}}
    end
  end

  defp open(state) do
    case selected(state) do
      nil -> state
      %{type: :directory} = entry -> descend(state, entry)
      _entry -> open_actions(state)
    end
  end

  defp descend(state, entry) do
    case Files.descend(state.location, entry.name) do
      {:ok, location} -> load(state, location)
      {:error, reason} -> %{state | message: {:error, "#{entry.name}: #{why(reason)}"}}
    end
  end

  defp back(%{location: %{path: []}} = state) do
    %{state | view: :places, location: nil, entries: [], cursor: 0, message: nil}
  end

  # Not at the top of a root, so `ascend/1` has a parent to give: the clause
  # above is the one that answers for the empty path.
  defp back(state) do
    load(state, Files.ascend(state.location), Path.basename(state.dir || ""))
  end

  # Read a directory and put the cursor somewhere sensible.
  #
  # `landing` is the name to select on arrival, which is how coming back up
  # puts the cursor on the directory just left rather than at the top -- the
  # difference between walking a tree and being teleported to the start of it
  # every time.
  #
  # A directory that cannot be read is a state to render, not an error to
  # raise: `/root/cores` does not exist until a core is installed, and the
  # games card's root does not exist with the card out. Both are things the
  # panel should say plainly.
  defp load(state, location, landing \\ nil) do
    {entries, readable?, message} =
      case Files.list(location) do
        {:ok, entries} -> {entries, true, nil}
        {:error, reason} -> {[], false, {:error, why(reason)}}
      end

    dir =
      case Files.resolve(location) do
        {:ok, dir} -> dir
        {:error, _reason} -> nil
      end

    cursor =
      case landing && Enum.find_index(entries, &(&1.name == landing)) do
        nil -> 0
        index -> index
      end

    %{
      state
      | view: :browse,
        location: location,
        dir: dir,
        entries: entries,
        cursor: cursor,
        readable?: readable?,
        space: Files.space(location),
        actions: [],
        action_cursor: 0,
        pending: nil,
        rename: nil,
        message: message
    }
  end

  # Re-read the current directory after an operation, keeping the cursor where
  # it was rather than where the name was: the name may be the one that just
  # went away.
  defp reload(state, message) do
    reloaded = load(state, state.location)
    count = length(reloaded.entries)

    %{reloaded | cursor: clamp(min(state.cursor, count - 1), count), message: message}
  end

  defp selected(%{entries: entries, cursor: cursor}), do: Enum.at(entries, cursor)

  # -- actions ----------------------------------------------------------------

  defp open_actions(%{view: :places} = state), do: state

  defp open_actions(state) do
    case actions_for(state) do
      [] -> %{state | message: {:ok, "Nothing to do here."}}
      actions -> %{state | view: :actions, actions: actions, action_cursor: 0, message: nil}
    end
  end

  @doc """
  The actions offered for the current selection and clipboard.

  Public because it is the part worth testing without a panel: which verbs are
  on offer is the whole safety story of the sheet -- a directory must not be
  offered a copy it cannot do, and paste must appear only when something is
  held.
  """
  @spec actions_for(map()) :: [map()]
  def actions_for(state) do
    paste_actions(state) ++ selection_actions(selected(state))
  end

  defp paste_actions(%{clipboard: nil}), do: []

  defp paste_actions(%{clipboard: %{mode: mode, name: name}, readable?: true}) do
    [
      %{id: :paste, label: "#{verb(mode)} #{name} here"},
      %{id: :forget, label: "Forget #{name}"}
    ]
  end

  defp paste_actions(%{clipboard: %{name: name}}) do
    [%{id: :forget, label: "Forget #{name}"}]
  end

  defp verb(:copy), do: "Paste a copy of"
  defp verb(:move), do: "Move"

  defp selection_actions(nil), do: []

  defp selection_actions(%{name: name} = entry) do
    copy =
      if entry.type == :regular and entry.link == nil do
        [%{id: :copy, label: "Copy #{name}"}]
      else
        []
      end

    copy ++
      [
        %{id: :move, label: "Move #{name}"},
        %{id: :rename, label: "Rename #{name}"},
        %{id: :delete, label: "Delete #{name}"}
      ]
  end

  defp run_action(state) do
    case Enum.at(state.actions, state.action_cursor) do
      nil -> %{state | view: :browse}
      action -> act(state, action.id)
    end
  end

  defp act(state, :copy), do: pick_up(state, :copy)
  defp act(state, :move), do: pick_up(state, :move)

  defp act(state, :forget) do
    %{state | view: :browse, clipboard: nil, actions: [], message: {:ok, "Clipboard cleared."}}
  end

  defp act(state, :delete) do
    case selected(state) do
      nil ->
        %{state | view: :browse}

      entry ->
        case Files.descend(state.location, entry.name) do
          {:ok, location} ->
            %{state | view: :confirm, pending: %{location: location, entry: entry}}

          {:error, reason} ->
            %{state | view: :browse, message: {:error, "#{entry.name}: #{why(reason)}"}}
        end
    end
  end

  defp act(state, :rename) do
    case selected(state) do
      nil ->
        %{state | view: :browse}

      entry ->
        %{
          state
          | view: :rename,
            rename: %{name: entry.name, chars: String.graphemes(entry.name), caret: 0},
            message: nil
        }
    end
  end

  defp act(%{clipboard: nil} = state, :paste), do: %{state | view: :browse}

  defp act(%{clipboard: %{mode: mode, location: source, name: name}} = state, :paste) do
    result =
      case mode do
        :copy -> Files.copy(source, state.location)
        :move -> Files.move(source, state.location)
      end

    case result do
      :ok ->
        # A move consumes the clipboard: the source is not there any more, so
        # a second paste could only fail. A copy keeps it, which is how the
        # same ROM gets onto both cards.
        clipboard = if mode == :move, do: nil, else: state.clipboard

        %{reload(state, {:ok, "#{name} #{done(mode)}."}) | clipboard: clipboard}

      {:error, reason} ->
        %{state | view: :browse, message: {:error, "#{name}: #{why(reason)}"}}
    end
  end

  defp act(state, _unknown), do: %{state | view: :browse}

  defp done(:copy), do: "copied here"
  defp done(:move), do: "moved here"

  defp pick_up(state, mode) do
    case selected(state) do
      nil ->
        %{state | view: :browse}

      entry ->
        case Files.descend(state.location, entry.name) do
          {:ok, location} ->
            %{
              state
              | view: :browse,
                actions: [],
                clipboard: %{mode: mode, location: location, name: entry.name},
                message: {:ok, "#{entry.name} held. Open a folder and press Y to put it there."}
            }

          {:error, reason} ->
            %{state | view: :browse, message: {:error, "#{entry.name}: #{why(reason)}"}}
        end
    end
  end

  # -- deleting ---------------------------------------------------------------

  defp confirm_delete(%{pending: nil} = state), do: %{state | view: :browse}

  defp confirm_delete(%{pending: %{location: location, entry: entry}} = state) do
    message =
      case Files.delete(location) do
        :ok -> {:ok, "#{entry.name} deleted."}
        {:error, reason} -> {:error, "#{entry.name}: #{why(reason)}"}
      end

    %{reload(state, message) | pending: nil}
  end

  # -- renaming ---------------------------------------------------------------

  defp move_caret(%{chars: chars, caret: caret} = rename, delta) do
    %{rename | caret: caret |> Kernel.+(delta) |> max(0) |> min(length(chars))}
  end

  # At the append position there is no character to change, so up or down puts
  # one there and leaves the caret on it -- pressing up again then steps that
  # character rather than adding a second one.
  defp step_char(%{chars: chars, caret: caret} = rename, delta) do
    if caret >= length(chars) do
      %{rename | chars: chars ++ [first_char(delta)]}
    else
      current = Enum.at(chars, caret)
      %{rename | chars: List.replace_at(chars, caret, next_char(current, delta))}
    end
  end

  defp first_char(delta), do: next_char(nil, delta)

  # A character the picker does not know about -- a ROM named in Japanese, say
  # -- has no position to step from, so the first press replaces it with the
  # start of the alphabet rather than doing nothing at all.
  defp next_char(current, delta) do
    case Enum.find_index(@alphabet, &(&1 == current)) do
      nil -> hd(@alphabet)
      index -> Enum.at(@alphabet, Integer.mod(index + delta, length(@alphabet)))
    end
  end

  defp drop_char(%{chars: []} = rename), do: rename

  defp drop_char(%{chars: chars, caret: caret} = rename) do
    at = min(caret, length(chars) - 1)
    chars = List.delete_at(chars, at)
    %{rename | chars: chars, caret: min(at, length(chars))}
  end

  # The name the editor was opened on, not whatever the cursor is on now. The
  # D-pad belongs to the editor while it is open so the two cannot currently
  # differ -- but "cannot currently" is not a thing to rename a file on.
  defp confirm_rename(%{rename: %{chars: chars, name: old}} = state) do
    new_name = Enum.join(chars)

    with {:ok, location} <- Files.descend(state.location, old),
         :ok <- Files.rename(location, new_name) do
      %{reload(state, {:ok, "#{old} is now #{new_name}."}) | rename: nil}
    else
      {:error, reason} -> %{state | message: {:error, "#{new_name}: #{why(reason)}"}}
    end
  end

  # -- words for the panel ----------------------------------------------------

  @doc """
  A reason in words, for the panel.

  Here rather than in the scene because these are the words that go in the
  ring log as well, and a device whose only forensics is `RingLogger.next`
  should not have two vocabularies for the same failure.
  """
  @spec why(term()) :: String.t()
  def why(:unknown_root), do: "not one of the places this app can open"
  def why(:bad_name), do: "that name is not allowed"
  def why(:is_root), do: "that is a whole root, not a file"
  def why(:eexist), do: "something with that name is already there"
  def why(:eisdir), do: "that is a directory; only files can be copied"
  def why(:enotdir), do: "that is not a directory"
  def why(:enoent), do: "it is not there"
  def why(:eacces), do: "no permission"
  def why(:erofs), do: "that filesystem is read-only"
  def why(:exdev), do: "a directory cannot be moved to another filesystem"
  def why(:enospc), do: "not enough free space"
  def why(:not_empty), do: "the directory is not empty"
  def why(:is_symlink), do: "that is a link; copy what it points at instead"
  def why(:same_path), do: "it is already there"
  def why({:unsupported, type}), do: "cannot handle a #{type}"
  def why({stage, reason}) when is_atom(stage), do: "#{stage} failed: #{why(reason)}"
  def why(other), do: inspect(other)
end
