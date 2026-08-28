defmodule MayonnaiOS.Browser do
  @moduledoc """
  The launcher's menu as a column browser: a stack of levels, Miller-columns
  style, and the focus is always the center of the panel. The left column is
  the level above -- blank at the root -- and the right column is not a level
  at all: it previews whatever the cursor is on. A directory previews as its
  contents, a file as its metadata and its first bytes (text, an image, or a
  hexdump, whichever the bytes are), a runnable row as what it is and that A
  opens it, and a process monitor as a narrow slice of the readout itself.

  A pure data structure with no process. `MayonnaiOS.Launcher` holds one of
  these in its own state -- the same place the flat cursor used to live, and
  for the same two reasons: input only reaches Elixir through the device the
  Launcher holds open, and `Scenic.ViewPort.set_root/3` restarts the scene on
  every repaint, so anything a scene remembered would be gone the moment a
  program exited. `MayonnaiOS.Scene.Home` draws whatever this module returns
  and owns nothing.

  ## The tree

  The root column is fixed: Games, Files, Apps, System. What each one
  contains is classified out of the one `config :mayonnaios, :programs` list
  the launcher already reads, so a row added to config appears in the right
  column with no code change here:

    * a `:path` entry is a game or program to run -- **Games**
    * a pickle's row (`{MayonnaiOS.Pickles.App, name}`) -- **Apps**
    * any other app, and every `:action` -- **System**

  A row can also name its column outright with `:category`, which overrides
  the rules above -- that is how the Bluetooth controller sits under **Apps**
  while the other built-in apps stay under **System**.

  System also carries two rows of the launcher's own, Diagnostics and
  Sleep, so the things the device can do to itself are on the menu rather
  than only on chords someone has to be told about.
  `MayonnaiOS.Launcher` owns what every verb does, this module only names
  them.

  ## Files is the same tree, continued -- and it is *the* file manager

  Descending into Files lists the roots `MayonnaiOS.Files.places/0` offers,
  and descending into a root just keeps browsing: every directory is another
  column. All of it goes through `MayonnaiOS.Files` locations -- a root key
  plus checked names -- so this module never assembles a path, and nothing
  outside the configured roots is reachable from the panel.

  A directory is read once, when its column is opened. The listing is a
  snapshot: cheap to move a cursor over, and refreshed by closing and
  reopening the column -- or by the operation that just changed it, which
  re-reads the column it acted on.

  ## The full view

  X toggles the **full view**: the columns give way to one wide column about
  the selected entry, built by `MayonnaiOS.Browser.View`. A directory becomes
  a detailed listing with sizes, a text file a viewer, an image the picture,
  any other file a hexdump, and a runnable row its metadata. While it is up,
  B and X close it and the directions scroll it -- `full_input/2` is the only
  input that belongs here, the way `overlay_input/2` is for the sheets. The
  process monitors are the one exception, and it is the launcher's: their
  detailed view is the `MayonnaiOS.Top` app itself, so X there starts it.

  ## The verbs, and the sheets they live behind

  Inside a directory column, Y -- and only Y -- opens the **actions sheet**:
  what can be done to the selected entry, plus pasting whatever the clipboard
  holds. A never opens it: A is the button that *opens things* -- it enters a
  directory, launches a program, views a file -- and a button that sometimes
  opens and sometimes asks is two buttons wearing one cap. The sheet is drawn
  as one more column, because in this UI "a list to pick from" and "a column"
  are the same thing.

  Copy and move are a clipboard, because there is no keyboard: pick an entry
  up, walk anywhere in the tree, and the sheet there offers to put it down.
  Nothing overwrites -- `MayonnaiOS.Files` refuses an existing destination --
  and a move clears the clipboard because the source is gone, while a copy
  keeps it, so the same ROM can be put on both cards.

  Deleting takes two presses on two different buttons: the sheet's Delete
  opens a confirmation naming the full path, and only Y -- not A, the button
  that asked -- deletes. A device that is switched off by pulling its power
  has no undo and no trash, so a second press of the same button is not a
  confirmation, it is a double-press waiting to happen.

  Renaming needs text and this handheld has none, so the rename editor is a
  character picker: left and right move the caret, up and down change the
  character under it, Y removes it, A saves. Slow and real -- the alternative
  is a rename verb that cannot be reached from the device.

  While a sheet, a confirmation or the rename editor is up, `busy?/1` is true
  and the Launcher routes every button through `overlay_input/2` instead of
  the navigation bindings, so a D-pad press cannot both move a caret and a
  cursor.
  """

  alias MayonnaiOS.{Files, Pickles, Programs}
  alias MayonnaiOS.Browser.View

  @typedoc "One entry in a column."
  @type node_ :: %{
          required(:kind) => :category | :place | :dir | :file | :program,
          required(:name) => String.t(),
          optional(atom()) => term()
        }

  @typedoc "One column: what it lists and which row is selected."
  @type level :: %{
          title: String.t(),
          entries: [node_()],
          cursor: non_neg_integer(),
          note: String.t() | nil,
          location: Files.location() | nil,
          readable?: boolean(),
          space: map() | nil
        }

  @typedoc "What has captured the buttons, if anything."
  @type overlay ::
          nil
          | {:actions, [%{id: atom(), label: String.t()}], non_neg_integer()}
          | {:confirm, %{location: Files.location(), entry: map(), name: String.t()}}
          | {:rename, %{name: String.t(), chars: [String.t()], caret: non_neg_integer()}}

  @typedoc """
  The whole browser: a stack of levels, a clipboard, one overlay, and --
  while X has it open -- the full view, a `MayonnaiOS.Browser.View.full/0`
  plus the scroll offset this module moves.
  """
  @type t :: %{
          levels: [level()],
          clipboard: %{mode: :copy | :move, location: Files.location(), name: String.t()} | nil,
          message: {:ok | :error, String.t()} | nil,
          overlay: overlay(),
          full: map() | nil
        }

  # How many lines the full view shows at once. The scene draws exactly this
  # many, read through `full_rows/0`, so paging and the panel cannot disagree
  # about what a screenful is.
  @full_rows 16

  # One screen. The scene shows ten rows; paging by ten keeps the shoulder
  # buttons and the scene in step without either reading the other.
  @page 10

  # What the rename editor can type. Not every character a filesystem accepts
  # -- a picker with a thousand entries is not a picker -- but every character
  # a ROM, a save or a directory on this device actually uses.
  @alphabet String.graphemes(
              "abcdefghijklmnopqrstuvwxyz" <>
                "ABCDEFGHIJKLMNOPQRSTUVWXYZ" <>
                "0123456789" <> ".-_ ()[]&'!+,"
            )

  @doc """
  A fresh browser: the root column, cursor on the first category.

  Reads nothing off the disk -- the root column is fixed -- so it is safe to
  build at boot, before anything is mounted.
  """
  @spec new() :: t()
  def new do
    %{levels: [root_level()], clipboard: nil, message: nil, overlay: nil, full: nil}
  end

  @doc "How many levels are open."
  @spec depth(t()) :: pos_integer()
  def depth(%{levels: levels}), do: length(levels)

  @doc "The node the cursor is on, or `nil` in an empty column."
  @spec selected(t()) :: node_() | nil
  def selected(%{levels: levels}) do
    %{entries: entries, cursor: cursor} = List.last(levels)
    Enum.at(entries, cursor)
  end

  @doc "The deepest column: the one the cursor lives in."
  @spec focused(t()) :: level()
  def focused(%{levels: levels}), do: List.last(levels)

  @doc """
  Whether an overlay -- the actions sheet, a delete confirmation, the rename
  editor -- has the buttons. While this is true, `overlay_input/2` is the
  only input that belongs here.
  """
  @spec busy?(t()) :: boolean()
  def busy?(%{overlay: overlay}), do: overlay != nil

  @doc """
  Move the cursor in the deepest column, wrapping at both ends.

  Wrapping rather than clamping because a single press is the only way to
  step: the last row of a long column is one press up from the first.
  """
  @spec move(t(), integer()) :: t()
  def move(%{levels: levels} = browser, delta) do
    %{entries: entries, cursor: cursor} = level = List.last(levels)

    case length(entries) do
      0 -> browser
      count -> put_last(browser, %{level | cursor: Integer.mod(cursor + delta, count)})
    end
  end

  @doc """
  Move the cursor a screenful, clamping at the ends.

  Clamping, unlike `move/2`: a page that wrapped would mean paging near the
  end of a long directory and landing back at the top, which reads as the
  browser having lost its place.
  """
  @spec page(t(), :up | :down) :: t()
  def page(browser, direction) do
    %{entries: entries, cursor: cursor} = level = focused(browser)
    delta = if direction == :up, do: -@page, else: @page

    case length(entries) do
      0 -> browser
      count -> put_last(browser, %{level | cursor: (cursor + delta) |> max(0) |> min(count - 1)})
    end
  end

  @doc """
  Whether descending into this node opens another column.

  The other kinds are leaves: a program is launched, a file gets its actions
  sheet.
  """
  @spec expandable?(node_() | nil) :: boolean()
  def expandable?(%{kind: kind}), do: kind in [:category, :place, :dir]
  def expandable?(nil), do: false

  @doc """
  Open the selected node as a new column.

  A leaf, or an empty column, leaves the browser unchanged -- the caller can
  compare and skip the repaint. This is the one navigation that reads the
  disk: a place or a directory is listed here, once, and the listing becomes
  the new column.
  """
  @spec descend(t()) :: t()
  def descend(%{levels: levels} = browser) do
    node = selected(browser)

    if expandable?(node) do
      %{browser | levels: levels ++ [expand(node)], message: nil}
    else
      browser
    end
  end

  @doc "Close the deepest column. At the root there is nothing to close."
  @spec ascend(t()) :: t()
  def ascend(%{levels: [_root]} = browser), do: browser

  def ascend(%{levels: levels} = browser) do
    %{browser | levels: Enum.drop(levels, -1), message: nil}
  end

  @doc """
  Back to the root column. The clipboard survives -- carrying a file across
  the tree is what it is for -- and any overlay or full view does not.
  """
  @spec reset(t()) :: t()
  def reset(browser) do
    %{browser | levels: [root_level()], message: nil, overlay: nil, full: nil}
  end

  @doc """
  The two levels the panel's left and center slots draw: the focused column,
  where the cursor lives, and its parent -- `nil` at the root, where blank on
  the left is the honest answer. The third slot is `preview/1`'s.
  """
  @spec panes(t()) :: %{left: level() | nil, center: level()}
  def panes(%{levels: [only]}), do: %{left: nil, center: only}
  def panes(%{levels: levels}), do: %{left: Enum.at(levels, -2), center: List.last(levels)}

  @doc """
  What the right pane says about the current selection, or `nil` with nothing
  selected.

  An expandable node -- a category, a root, a directory -- previews as the
  column a descend would open, through the same expansion, so the preview and
  the descent cannot disagree about what is inside. Leaves are
  `MayonnaiOS.Browser.View`'s: file contents, program metadata, the narrow
  process list.

  Built fresh on every call rather than stored, because it is derived from
  the selection and the disk -- the scene asks when it draws, and holding a
  copy here would only be one more thing to go stale.
  """
  @spec preview(t()) :: map() | nil
  def preview(browser) do
    node = selected(browser)

    cond do
      node == nil -> nil
      expandable?(node) -> %{kind: :level, level: expand(node)}
      true -> View.preview(node, focused(browser).location)
    end
  end

  # -- the full view --------------------------------------------------------------

  @doc """
  Whether the full view -- one wide column -- has the panel. While this is
  true, `full_input/2` is the only input that belongs here.
  """
  @spec full?(t()) :: boolean()
  def full?(%{full: full}), do: full != nil

  @doc """
  Open the full view of the selected entry: X's half of the toggle, and A's
  way of opening a file that cannot be entered or run.

  An entry with no full view -- a category, an empty column -- leaves the
  browser unchanged, so the caller can compare and skip the repaint. The
  process monitors never arrive here from a button: the launcher starts the
  `MayonnaiOS.Top` app instead, because the app is their detailed view.
  """
  @spec open_full(t()) :: t()
  def open_full(browser) do
    node = selected(browser)

    case node && View.full(node, focused(browser).location) do
      nil -> browser
      full -> %{browser | full: Map.put(full, :offset, 0), message: nil}
    end
  end

  @doc "Close the full view. Back to the columns, exactly as they were."
  @spec close_full(t()) :: t()
  def close_full(browser), do: %{browser | full: nil}

  @doc "How many lines the full view shows at once; the scene draws this many."
  @spec full_rows() :: pos_integer()
  def full_rows, do: @full_rows

  @doc """
  One button, while the full view is up.

  B closes it -- in the full view, back always goes back -- and so does X,
  because a toggle that only toggles one way is a door with no handle on the
  inside. The directions and the shoulders scroll anything with lines, and
  everything else is swallowed: a press meant for this view must not also
  move a cursor in a column that is not on the panel.
  """
  @spec full_input(t(), atom()) :: t()
  def full_input(%{full: nil} = browser, _button), do: browser

  def full_input(browser, button) do
    case button do
      :b -> close_full(browser)
      :x -> close_full(browser)
      :up -> scroll_full(browser, -1)
      :down -> scroll_full(browser, +1)
      :left -> scroll_full(browser, -@full_rows)
      :right -> scroll_full(browser, +@full_rows)
      :l1 -> scroll_full(browser, -@full_rows)
      :r1 -> scroll_full(browser, +@full_rows)
      _other -> browser
    end
  end

  # Clamped like `page/2` and for the same reason; a view with no lines -- an
  # image -- has nowhere to scroll to and stays put.
  defp scroll_full(%{full: full} = browser, delta) do
    ceiling = max(length(Map.get(full, :lines, [])) - @full_rows, 0)
    offset = (full.offset + delta) |> max(0) |> min(ceiling)
    %{browser | full: %{full | offset: offset}}
  end

  @doc """
  The titles of every open level, root first, for the breadcrumb line.

  The panel draws all of them even when only the deepest columns fit, so the
  line still says where you are when the root has scrolled off.
  """
  @spec trail(t()) :: [String.t()]
  def trail(%{levels: levels}), do: Enum.map(levels, & &1.title)

  # -- the actions sheet --------------------------------------------------------

  @doc """
  Open the actions sheet for the current selection and clipboard.

  Only inside a directory column -- the categories and the programs have no
  file verbs -- and only when there is something to offer: with nothing
  selected and nothing held, the message says so instead of an empty sheet.
  """
  @spec open_actions(t()) :: t()
  def open_actions(browser) do
    cond do
      focused(browser).location == nil ->
        browser

      actions_for(browser) == [] ->
        %{browser | message: {:ok, "Nothing to do here."}}

      true ->
        %{browser | overlay: {:actions, actions_for(browser), 0}, message: nil}
    end
  end

  @doc """
  The actions offered for the current selection and clipboard.

  Public because it is the part worth testing without a panel: which verbs
  are on offer is the whole safety story of the sheet -- a directory must not
  be offered a copy it cannot do, and paste must appear only when something
  is held and the column can take it.
  """
  @spec actions_for(t()) :: [map()]
  def actions_for(browser) do
    paste_actions(browser.clipboard, focused(browser).readable?) ++
      selection_actions(selected(browser))
  end

  defp paste_actions(nil, _readable?), do: []

  defp paste_actions(%{mode: mode, name: name}, true) do
    [
      %{id: :paste, label: "#{verb(mode)} #{name} here"},
      %{id: :forget, label: "Forget #{name}"}
    ]
  end

  defp paste_actions(%{name: name}, false) do
    [%{id: :forget, label: "Forget #{name}"}]
  end

  defp verb(:copy), do: "Paste a copy of"
  defp verb(:move), do: "Move"

  defp selection_actions(%{kind: kind, name: name, entry: entry}) when kind in [:file, :dir] do
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

  defp selection_actions(_node), do: []

  # -- overlay input ------------------------------------------------------------

  @doc """
  One button, while an overlay has them.

  `button` is the launcher's translation -- `:up`, `:down`, `:left`,
  `:right`, `:a`, `:b`, `:y`, or `:other` for anything else it holds open.
  The rules are the file manager's classics: on the confirmation **only Y
  deletes** and every other button -- A included, deliberately -- backs out;
  in the rename editor the D-pad belongs to the caret.
  """
  @spec overlay_input(t(), atom()) :: t()
  def overlay_input(%{overlay: {:actions, actions, cursor}} = browser, button) do
    count = length(actions)

    case button do
      :up -> %{browser | overlay: {:actions, actions, Integer.mod(cursor - 1, count)}}
      :down -> %{browser | overlay: {:actions, actions, Integer.mod(cursor + 1, count)}}
      :a -> run_action(browser, Enum.at(actions, cursor))
      :b -> %{browser | overlay: nil}
      _other -> browser
    end
  end

  def overlay_input(%{overlay: {:confirm, pending}} = browser, :y) do
    confirm_delete(browser, pending)
  end

  def overlay_input(%{overlay: {:confirm, _pending}} = browser, _button) do
    %{browser | overlay: nil, message: {:ok, "Nothing was deleted."}}
  end

  def overlay_input(%{overlay: {:rename, rename}} = browser, button) do
    case button do
      :left -> %{browser | overlay: {:rename, move_caret(rename, -1)}}
      :right -> %{browser | overlay: {:rename, move_caret(rename, +1)}}
      :up -> %{browser | overlay: {:rename, step_char(rename, -1)}}
      :down -> %{browser | overlay: {:rename, step_char(rename, +1)}}
      :y -> %{browser | overlay: {:rename, drop_char(rename)}}
      :a -> confirm_rename(browser, rename)
      :b -> %{browser | overlay: nil, message: {:ok, "Rename cancelled."}}
      _other -> browser
    end
  end

  def overlay_input(browser, _button), do: browser

  # -- the verbs ----------------------------------------------------------------

  defp run_action(browser, nil), do: %{browser | overlay: nil}
  defp run_action(browser, %{id: id}), do: act(browser, id)

  defp act(browser, :copy), do: pick_up(browser, :copy)
  defp act(browser, :move), do: pick_up(browser, :move)

  defp act(browser, :forget) do
    %{browser | overlay: nil, clipboard: nil, message: {:ok, "Clipboard cleared."}}
  end

  defp act(browser, :delete) do
    with_selected(browser, fn node, location ->
      case Files.descend(location, node.name) do
        {:ok, target} ->
          %{
            browser
            | overlay: {:confirm, %{location: target, entry: node.entry, name: node.name}}
          }

        {:error, reason} ->
          %{browser | overlay: nil, message: {:error, "#{node.name}: #{why(reason)}"}}
      end
    end)
  end

  defp act(browser, :rename) do
    with_selected(browser, fn node, _location ->
      rename = %{name: node.name, chars: String.graphemes(node.name), caret: 0}
      %{browser | overlay: {:rename, rename}, message: nil}
    end)
  end

  defp act(%{clipboard: nil} = browser, :paste), do: %{browser | overlay: nil}

  defp act(%{clipboard: %{mode: mode, location: source, name: name}} = browser, :paste) do
    destination = focused(browser).location

    result =
      case mode do
        :copy -> Files.copy(source, destination)
        :move -> Files.move(source, destination)
      end

    case result do
      :ok ->
        # A move consumes the clipboard: the source is not there any more, so
        # a second paste could only fail. A copy keeps it, which is how the
        # same ROM gets onto both cards.
        clipboard = if mode == :move, do: nil, else: browser.clipboard

        %{reload(browser, {:ok, "#{name} #{done(mode)}."}) | clipboard: clipboard}

      {:error, reason} ->
        %{browser | overlay: nil, message: {:error, "#{name}: #{why(reason)}"}}
    end
  end

  defp act(browser, _unknown), do: %{browser | overlay: nil}

  defp done(:copy), do: "copied here"
  defp done(:move), do: "moved here"

  defp pick_up(browser, mode) do
    with_selected(browser, fn node, location ->
      case Files.descend(location, node.name) do
        {:ok, target} ->
          %{
            browser
            | overlay: nil,
              clipboard: %{mode: mode, location: target, name: node.name},
              message: {:ok, "#{node.name} held. Open a folder and press Y to put it there."}
          }

        {:error, reason} ->
          %{browser | overlay: nil, message: {:error, "#{node.name}: #{why(reason)}"}}
      end
    end)
  end

  # The sheet was opened on a selection; if the column has meanwhile lost it
  # -- it cannot today, the sheet has the buttons -- closing the sheet is the
  # honest answer, not acting on whatever the cursor lands on.
  defp with_selected(browser, fun) do
    case {selected(browser), focused(browser).location} do
      {nil, _location} -> %{browser | overlay: nil}
      {_node, nil} -> %{browser | overlay: nil}
      {node, location} -> fun.(node, location)
    end
  end

  defp confirm_delete(browser, %{location: location, entry: _entry, name: name}) do
    message =
      case Files.delete(location) do
        :ok -> {:ok, "#{name} deleted."}
        {:error, reason} -> {:error, "#{name}: #{why(reason)}"}
      end

    reload(browser, message)
  end

  # The name the editor was opened on, not whatever the cursor is on now. The
  # D-pad belongs to the editor while it is open so the two cannot currently
  # differ -- but "cannot currently" is not a thing to rename a file on.
  defp confirm_rename(browser, %{chars: chars, name: old}) do
    new_name = Enum.join(chars)
    location = focused(browser).location

    with {:ok, target} <- Files.descend(location, old),
         :ok <- Files.rename(target, new_name) do
      reload(browser, {:ok, "#{old} is now #{new_name}."})
    else
      {:error, reason} -> %{browser | message: {:error, "#{new_name}: #{why(reason)}"}}
    end
  end

  # Re-read the column an operation just changed, keeping the cursor where it
  # was rather than where the name was: the name may be the one that just
  # went away.
  defp reload(browser, message) do
    level = focused(browser)
    fresh = listing_level(level.title, level.location)
    cursor = level.cursor |> min(length(fresh.entries) - 1) |> max(0)

    put_last(%{browser | overlay: nil, message: message}, %{fresh | cursor: cursor})
  end

  # -- the rename editor --------------------------------------------------------

  defp move_caret(%{chars: chars, caret: caret} = rename, delta) do
    %{rename | caret: caret |> Kernel.+(delta) |> max(0) |> min(length(chars))}
  end

  # At the append position there is no character to change, so up or down puts
  # one there and leaves the caret on it -- pressing up again then steps that
  # character rather than adding a second one.
  defp step_char(%{chars: chars, caret: caret} = rename, delta) do
    if caret >= length(chars) do
      %{rename | chars: chars ++ [next_char(nil, delta)]}
    else
      current = Enum.at(chars, caret)
      %{rename | chars: List.replace_at(chars, caret, next_char(current, delta))}
    end
  end

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

  defp put_last(%{levels: levels} = browser, level) do
    %{browser | levels: List.replace_at(levels, -1, level)}
  end

  # -- the tree -----------------------------------------------------------------

  defp root_level do
    category_names = [
      %{kind: :category, id: :games, name: "Games"},
      %{kind: :category, id: :files, name: "Files"},
      %{kind: :category, id: :apps, name: "Apps"},
      %{kind: :category, id: :system, name: "System"}
    ]

    level("RG40XXV", category_names, nil)
  end

  defp expand(%{kind: :category, id: id, name: name}), do: category_level(id, name)
  defp expand(%{kind: :place} = node), do: place_level(node)
  defp expand(%{kind: :dir} = node), do: dir_level(node)

  defp category_level(:games, name) do
    rows = for program <- classified(:games), do: program_node(program)
    level(name, rows, "Nothing to run. Install a bundle, or check the config.")
  end

  defp category_level(:apps, name) do
    rows = for program <- classified(:apps), do: program_node(program)
    level(name, rows, "No apps installed.")
  end

  defp category_level(:files, name) do
    places = for place <- Files.places(), do: place_node(place)
    level(name, places, "No roots configured.")
  end

  defp category_level(:system, name) do
    {actions, apps} = Enum.split_with(classified(:system), &(&1.action != nil))

    rows =
      Enum.map(apps, &program_node/1) ++
        [
          program_node(builtin("Diagnostics", :diagnostics)),
          program_node(builtin("Sleep", :sleep))
        ] ++
        Enum.map(actions, &program_node/1)

    level(name, rows, nil)
  end

  # The one config list, classified. `Programs.list/0` already appends the
  # installed pickles' rows, which is what makes the Apps column honest:
  # it shows what is on the disk now, not what config promised.
  defp classified(category) do
    Enum.filter(Programs.list(), &(classify(&1) == category))
  end

  # A row's own `:category` wins, so config can put an app wherever it
  # belongs -- the Bluetooth controller is a thing to use, not a setting.
  defp classify(%{category: category}) when category != nil, do: category
  defp classify(%{action: action}) when action != nil, do: :system
  defp classify(%{app: {Pickles.App, _name}}), do: :apps
  defp classify(%{app: app}) when app != nil, do: :system
  defp classify(_program), do: :games

  # A verb of the launcher's own, shaped like a config row so the launcher's
  # `start_program/2` needs no second vocabulary for it.
  defp builtin(name, action) do
    %{
      name: name,
      path: nil,
      app: nil,
      action: action,
      args: [],
      needs_udev: false,
      installed?: true
    }
  end

  defp program_node(program) do
    %{kind: :program, name: program.name, program: program}
  end

  defp place_node(place) do
    %{kind: :place, name: place.path, key: place.key, note: place.note}
  end

  defp place_level(%{key: key, name: name}) do
    case Files.at(key) do
      {:ok, location} -> listing_level(name, location)
      {:error, reason} -> level(name, [], "cannot be opened: #{why(reason)}")
    end
  end

  defp dir_level(%{name: name, location: location}), do: listing_level(name, location)

  # A directory that cannot be read is a column to draw, not an error to
  # raise: the games card's root does not exist with the card out, and the
  # panel should say so where the listing would have been. `readable?` is
  # what gates the paste action -- a column that could not be read is not a
  # place to put anything.
  defp listing_level(title, location) do
    case Files.list(location) do
      {:ok, entries} ->
        %{
          title: title,
          entries: Enum.map(entries, &entry_node(location, &1)),
          cursor: 0,
          note: if(entries == [], do: "Empty."),
          location: location,
          readable?: true,
          space: Files.space(location)
        }

      {:error, reason} ->
        %{
          title: title,
          entries: [],
          cursor: 0,
          note: "cannot be read: #{why(reason)}",
          location: location,
          readable?: false,
          space: nil
        }
    end
  end

  # A directory entry becomes a column entry. The child location is built
  # here, through the same checked constructor everything else uses -- a name
  # the boundary refuses (it happens: a name can exceed the length cap) stays
  # visible but is a leaf, so it can be seen and not entered.
  defp entry_node(location, %{type: :directory, name: name} = entry) do
    case Files.descend(location, name) do
      {:ok, child} -> %{kind: :dir, name: name, location: child, entry: entry}
      {:error, _reason} -> %{kind: :file, name: name, entry: entry}
    end
  end

  defp entry_node(_location, %{name: name} = entry) do
    %{kind: :file, name: name, entry: entry}
  end

  # A category column: nothing on the disk to act on, so no location, no
  # paste, no free-space line.
  defp level(title, entries, empty_note) do
    %{
      title: title,
      entries: entries,
      cursor: 0,
      note: if(entries == [], do: empty_note),
      location: nil,
      readable?: false,
      space: nil
    }
  end

  # -- words for the panel --------------------------------------------------------

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
