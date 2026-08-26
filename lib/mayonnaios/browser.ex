defmodule MayonnaiOS.Browser do
  @moduledoc """
  The launcher's menu as a column browser: a stack of levels, NeXTSTEP-style,
  where the first column is the categories and every descent opens another
  column to the right.

  A pure data structure with no process. `MayonnaiOS.Launcher` holds one of
  these in its own state -- the same place the flat cursor used to live, and
  for the same two reasons: input only reaches Elixir through the device the
  Launcher holds open, and `Scenic.ViewPort.set_root/3` restarts the scene on
  every repaint, so anything a scene remembered would be gone the moment a
  program exited. `MayonnaiOS.Scene.Home` draws whatever this module returns
  and owns nothing.

  ## The tree

  The root column is fixed: Games, Files, Pickles, Settings. What each one
  contains is classified out of the one `config :mayonnaios, :programs` list
  the launcher already reads, so a row added to config appears in the right
  column with no code change here:

    * a `:path` entry is a game or program to run -- **Games**
    * a pickle's row (`{MayonnaiOS.Pickles.App, name}`) -- **Pickles**
    * the file manager app -- the first row of **Files**, above the roots
    * any other app, and every `:action` -- **Settings**

  Settings also carries two rows of the launcher's own, Diagnostics and
  Sleep, so the things the device can do to itself are on the menu rather
  than only on chords someone has to be told about. The chords still work;
  `MayonnaiOS.Launcher` owns what every verb does, this module only names
  them.

  ## Files is the same tree, continued

  Descending into Files lists the roots `MayonnaiOS.Files.places/0` offers,
  and descending into a root just keeps browsing: every directory is another
  column. All of it goes through `MayonnaiOS.Files` locations -- a root key
  plus checked names -- so this module never assembles a path, and nothing
  outside the configured roots is reachable from the panel. Browsing here is
  looking; the file manager app (the first row of the column) is where
  delete, rename, copy and move live, with their confirmations.

  A directory is read once, when its column is opened. The listing is a
  snapshot: cheap to move a cursor over, and refreshed by closing and
  reopening the column rather than by re-reading the disk on every press.

  ## Columns are a view setting, not a place

  `columns` says how many of the deepest levels the panel draws -- 1, 2 or 3
  -- and `cycle_columns/1` steps through them. It changes nothing about where
  the cursor is: the model is always the full stack, and the scene shows the
  tail of it.
  """

  alias MayonnaiOS.{Files, Pickles, Programs}

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
          note: String.t() | nil
        }

  @typedoc "The whole browser: a stack of levels and how many to draw."
  @type t :: %{levels: [level()], columns: 1..3}

  # The visible-column settings the shortcut cycles through, in order.
  @column_settings [1, 2, 3]

  @doc """
  A fresh browser: the root column, cursor on the first category.

  Reads nothing off the disk -- the root column is fixed -- so it is safe to
  build at boot, before anything is mounted.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %{levels: [root_level()], columns: Keyword.get(opts, :columns, 2)}
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

  @doc """
  Move the cursor in the deepest column, wrapping at both ends.

  Wrapping rather than clamping because the D-pad is the only way to move:
  the last row of a long column is one press up from the first.
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
  Whether descending into this node opens another column.

  The other kinds are leaves: a program is launched, a file is only named.
  """
  @spec expandable?(node_() | nil) :: boolean()
  def expandable?(%{kind: kind}), do: kind in [:category, :place, :dir]
  def expandable?(nil), do: false

  @doc """
  Open the selected node as a new column.

  A leaf, or an empty column, leaves the browser unchanged -- the caller can
  compare and skip the repaint. This is the one function that reads the disk:
  a place or a directory is listed here, once, and the listing becomes the
  new column.
  """
  @spec descend(t()) :: t()
  def descend(%{levels: levels} = browser) do
    node = selected(browser)

    if expandable?(node) do
      %{browser | levels: levels ++ [expand(node)]}
    else
      browser
    end
  end

  @doc "Close the deepest column. At the root there is nothing to close."
  @spec ascend(t()) :: t()
  def ascend(%{levels: [_root]} = browser), do: browser
  def ascend(%{levels: levels} = browser), do: %{browser | levels: Enum.drop(levels, -1)}

  @doc "Back to the root column, keeping the column-count setting."
  @spec reset(t()) :: t()
  def reset(browser), do: %{browser | levels: [root_level()]}

  @doc "The next visible-column setting: 1, 2, 3, and round again."
  @spec cycle_columns(t()) :: t()
  def cycle_columns(%{columns: columns} = browser) do
    index = Enum.find_index(@column_settings, &(&1 == columns)) || 1

    %{
      browser
      | columns: Enum.at(@column_settings, Integer.mod(index + 1, length(@column_settings)))
    }
  end

  @doc """
  The levels the panel should draw: the deepest ones, at most `columns`.

  The head of the result is the leftmost column and the last is the focused
  one -- the only one whose cursor the D-pad moves.
  """
  @spec visible(t()) :: [level()]
  def visible(%{levels: levels, columns: columns}) do
    Enum.take(levels, -min(columns, length(levels)))
  end

  @doc """
  The titles of every open level, root first, for the breadcrumb line.

  The panel draws all of them even when only the deepest columns fit, so a
  one-column view still says where it is.
  """
  @spec trail(t()) :: [String.t()]
  def trail(%{levels: levels}), do: Enum.map(levels, & &1.title)

  defp put_last(%{levels: levels} = browser, level) do
    %{browser | levels: List.replace_at(levels, -1, level)}
  end

  # -- the tree ---------------------------------------------------------------

  defp root_level do
    %{
      title: "RG40XXV",
      cursor: 0,
      note: nil,
      entries: [
        %{kind: :category, id: :games, name: "Games"},
        %{kind: :category, id: :files, name: "Files"},
        %{kind: :category, id: :pickles, name: "Pickles"},
        %{kind: :category, id: :settings, name: "Settings"}
      ]
    }
  end

  defp expand(%{kind: :category, id: id, name: name}), do: category_level(id, name)
  defp expand(%{kind: :place} = node), do: place_level(node)
  defp expand(%{kind: :dir} = node), do: dir_level(node)

  defp category_level(:games, name) do
    rows = for program <- classified(:games), do: program_node(program)
    level(name, rows, "Nothing to run. Install a bundle, or check the config.")
  end

  defp category_level(:pickles, name) do
    rows = for program <- classified(:pickles), do: program_node(program)
    level(name, rows, "No pickles installed.")
  end

  defp category_level(:files, name) do
    manager = for program <- classified(:files), do: program_node(program)
    places = for place <- Files.places(), do: place_node(place)
    level(name, manager ++ places, "No roots configured.")
  end

  defp category_level(:settings, name) do
    {actions, apps} = Enum.split_with(classified(:settings), &(&1.action != nil))

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
  # installed pickles' rows, which is what makes the Pickles column honest:
  # it shows what is on the disk now, not what config promised.
  defp classified(category) do
    Enum.filter(Programs.list(), &(classify(&1) == category))
  end

  defp classify(%{action: action}) when action != nil, do: :settings
  defp classify(%{app: {Pickles.App, _name}}), do: :pickles
  defp classify(%{app: MayonnaiOS.FileManager}), do: :files
  defp classify(%{app: app}) when app != nil, do: :settings
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
  # panel should say so where the listing would have been.
  defp listing_level(title, location) do
    case Files.list(location) do
      {:ok, entries} ->
        level(title, Enum.map(entries, &entry_node(location, &1)), "Empty.")

      {:error, reason} ->
        level(title, [], "cannot be read: #{why(reason)}")
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

  defp level(title, entries, empty_note) do
    %{title: title, entries: entries, cursor: 0, note: if(entries == [], do: empty_note)}
  end

  # The same words the file manager uses for the same failures, because the
  # two screens describe the same disk.
  defp why(reason), do: MayonnaiOS.FileManager.why(reason)
end
