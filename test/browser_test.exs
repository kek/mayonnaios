defmodule MayonnaiOS.BrowserTest do
  use ExUnit.Case, async: false

  alias MayonnaiOS.Browser

  # No process and no panel: the browser is a value, and these tests move it
  # the way the Launcher's bindings do and look at what a scene would draw.
  # The file operations run against a real temporary directory, because the
  # thing being asserted is what ends up on a disk, and a mock would only
  # assert that the test agrees with itself.

  setup do
    # `Programs.list/0` appends a row for every installed pickle, read from
    # disk on every call -- so without this, the Apps column is however
    # many pickles the developer happens to have installed on the host.
    pickles_root =
      Path.join(System.tmp_dir!(), "browser-test-pickles-#{System.unique_integer([:positive])}")

    File.mkdir_p!(pickles_root)
    previous = Application.get_env(:mayonnaios, :pickles_root)
    Application.put_env(:mayonnaios, :pickles_root, pickles_root)

    on_exit(fn ->
      File.rm_rf(pickles_root)
      Application.delete_env(:mayonnaios, :programs)
      Application.delete_env(:mayonnaios, :file_roots)

      case previous do
        nil -> Application.delete_env(:mayonnaios, :pickles_root)
        value -> Application.put_env(:mayonnaios, :pickles_root, value)
      end
    end)

    :ok
  end

  describe "the root column" do
    test "names the categories, in order" do
      browser = Browser.new()

      assert names(browser) == ["Games", "Files", "Apps", "System"]
      assert Browser.depth(browser) == 1
      assert Browser.selected(browser).name == "Games"
    end

    test "the cursor wraps at both ends" do
      browser = Browser.new()

      assert Browser.selected(Browser.move(browser, -1)).name == "System"
      assert Browser.selected(Browser.move(browser, 4)).name == "Games"
    end

    test "ascend at the root is a no-op, so B cannot fall off the top" do
      browser = Browser.new()
      assert Browser.ascend(browser) == browser
    end
  end

  describe "classifying the one config list" do
    setup do
      Application.put_env(:mayonnaios, :programs, [
        %{name: "RetroArch", path: "/nonexistent/retroarch"},
        %{name: "Bluetooth controller", app: MayonnaiOS.Controller, category: :apps},
        %{name: "Bluetooth devices", app: MayonnaiOS.Pairing},
        %{name: "Paint", app: {MayonnaiOS.Pickles.App, "paint"}},
        %{name: "Power off", action: :poweroff}
      ])

      :ok
    end

    test "a path entry is a game" do
      games = open(Browser.new(), "Games")
      assert names(games) == ["RetroArch"]
    end

    test "pickles land in Apps, and so does a row whose config names the category" do
      apps = open(Browser.new(), "Apps")
      assert names(apps) == ["Bluetooth controller", "Paint"]
    end

    test "Files lists the roots" do
      Application.put_env(:mayonnaios, :file_roots, [%{key: "r", path: "/tmp", note: ""}])

      files = open(Browser.new(), "Files")
      assert names(files) == ["/tmp"]
      assert Browser.selected(files).kind == :place
    end

    test "other apps and the actions land in System, verbs last" do
      system = open(Browser.new(), "System")

      assert names(system) == ["Bluetooth devices", "Diagnostics", "Sleep", "Power off"]
    end

    test "the built-in System rows carry the launcher's own verbs" do
      system = open(Browser.new(), "System")

      actions =
        for node <- List.last(system.levels).entries, do: node.program.action

      assert actions == [nil, :diagnostics, :sleep, :poweroff]
    end
  end

  describe "an empty category" do
    test "says why instead of listing nothing" do
      Application.put_env(:mayonnaios, :programs, [])

      apps = open(Browser.new(), "Apps")
      assert names(apps) == []
      assert List.last(apps.levels).note == "No apps installed."
    end
  end

  describe "browsing files" do
    setup :tmp_tree

    test "a root opens as a column of its entries", %{root: root} do
      browser = Browser.new() |> open("Files")

      assert Browser.selected(browser).name == root
      browser = Browser.descend(browser)

      # Directories first is Files.list/1's order; the browser keeps it.
      assert names(browser) == ["backup", "snes", "readme.txt"]
      assert Browser.trail(browser) == ["RG40XXV", "Files", root]
    end

    test "a directory keeps opening columns, and ascend walks back" do
      browser = Browser.new() |> into_root() |> select("snes") |> Browser.descend()

      assert names(browser) == ["chrono.sfc"]
      assert Browser.depth(browser) == 4

      assert browser |> Browser.ascend() |> names() == ["backup", "snes", "readme.txt"]
    end

    test "a file is a leaf: descend does nothing" do
      browser = Browser.new() |> into_root() |> select("readme.txt")

      assert %{kind: :file} = Browser.selected(browser)
      refute Browser.expandable?(Browser.selected(browser))
      assert Browser.descend(browser) == browser
    end

    test "a root that is not there is a column that says so" do
      browser = Browser.new() |> open("Files") |> Browser.move(1) |> Browser.descend()

      assert names(browser) == []
      assert Browser.focused(browser).note =~ "cannot be read"
      refute Browser.focused(browser).readable?
    end

    test "paging clamps instead of wrapping" do
      browser = Browser.new() |> into_root()

      paged = Browser.page(browser, :down)
      assert Browser.focused(paged).cursor == 2

      assert Browser.focused(Browser.page(paged, :up)).cursor == 0

      assert Browser.page(Browser.page(paged, :up), :up) |> Browser.focused() |> Map.get(:cursor) ==
               0
    end

    test "visible/1 is the deepest three levels" do
      browser = Browser.new() |> into_root() |> select("snes") |> Browser.descend()

      assert Browser.depth(browser) == 4
      assert Enum.map(Browser.visible(browser), & &1.title) |> length() == 3
      assert List.last(Browser.visible(browser)).title == "snes"
    end
  end

  describe "the actions sheet" do
    setup :tmp_tree

    test "a file is offered copy, move, rename and delete" do
      browser = Browser.new() |> into_root() |> select("readme.txt") |> Browser.open_actions()

      assert {:actions, actions, 0} = browser.overlay
      assert Enum.map(actions, & &1.id) == [:copy, :move, :rename, :delete]
      assert Browser.busy?(browser)
    end

    test "a directory is not offered a copy it cannot do" do
      browser = Browser.new() |> into_root() |> select("snes") |> Browser.open_actions()

      assert {:actions, actions, 0} = browser.overlay
      assert Enum.map(actions, & &1.id) == [:move, :rename, :delete]
    end

    test "outside a directory column there is no sheet" do
      browser = Browser.new()
      assert Browser.open_actions(browser) == browser

      games = open(browser, "Games")
      assert Browser.open_actions(games) == games
    end

    test "B closes the sheet without doing anything" do
      browser =
        Browser.new()
        |> into_root()
        |> select("readme.txt")
        |> Browser.open_actions()
        |> Browser.overlay_input(:b)

      refute Browser.busy?(browser)
      assert names(browser) == ["backup", "snes", "readme.txt"]
    end
  end

  describe "copy and move are a clipboard" do
    setup :tmp_tree

    test "copy holds the file, paste puts a copy down, and the clipboard keeps", %{root: root} do
      browser =
        Browser.new()
        |> into_root()
        |> select("readme.txt")
        |> Browser.open_actions()
        |> act(:copy)

      assert browser.clipboard.name == "readme.txt"
      assert {:ok, _held} = browser.message

      browser =
        browser
        |> select("backup")
        |> Browser.descend()
        |> Browser.open_actions()
        |> act(:paste)

      assert {:ok, "readme.txt copied here."} = browser.message
      assert names(browser) == ["readme.txt"]
      assert File.exists?(Path.join(root, "backup/readme.txt"))
      assert File.exists?(Path.join(root, "readme.txt"))

      # A copy keeps the clipboard, which is how the same ROM gets onto both
      # cards.
      assert browser.clipboard != nil
    end

    test "a move removes the source and consumes the clipboard", %{root: root} do
      browser =
        Browser.new()
        |> into_root()
        |> select("readme.txt")
        |> Browser.open_actions()
        |> act(:move)
        |> select("backup")
        |> Browser.descend()
        |> Browser.open_actions()
        |> act(:paste)

      assert {:ok, "readme.txt moved here."} = browser.message
      assert File.exists?(Path.join(root, "backup/readme.txt"))
      refute File.exists?(Path.join(root, "readme.txt"))
      assert browser.clipboard == nil
    end

    test "nothing overwrites: pasting onto an existing name is refused", %{root: root} do
      browser =
        Browser.new()
        |> into_root()
        |> select("readme.txt")
        |> Browser.open_actions()
        |> act(:copy)
        |> Browser.open_actions()
        |> act(:paste)

      assert {:error, message} = browser.message
      assert message =~ "already there"
      assert File.read!(Path.join(root, "readme.txt")) == "hi"
    end

    test "an unreadable column offers only to forget what is held" do
      browser =
        Browser.new()
        |> into_root()
        |> select("readme.txt")
        |> Browser.open_actions()
        |> act(:copy)
        |> Browser.ascend()
        |> Browser.move(1)
        |> Browser.descend()

      refute Browser.focused(browser).readable?

      browser = Browser.open_actions(browser)
      assert {:actions, actions, 0} = browser.overlay
      assert Enum.map(actions, & &1.id) == [:forget]

      browser = act(browser, :forget)
      assert browser.clipboard == nil
      assert {:ok, "Clipboard cleared."} = browser.message
    end
  end

  describe "deleting takes two presses, on two different buttons" do
    setup :tmp_tree

    test "A on the confirmation cancels; only Y deletes", %{root: root} do
      browser =
        Browser.new()
        |> into_root()
        |> select("readme.txt")
        |> Browser.open_actions()
        |> act(:delete)

      assert {:confirm, %{name: "readme.txt"}} = browser.overlay

      # A -- the button that opened the question -- backs out.
      cancelled = Browser.overlay_input(browser, :a)
      refute Browser.busy?(cancelled)
      assert {:ok, "Nothing was deleted."} = cancelled.message
      assert File.exists?(Path.join(root, "readme.txt"))

      # Y -- the button that did not ask -- deletes, and the column reloads.
      deleted = Browser.overlay_input(browser, :y)
      assert {:ok, "readme.txt deleted."} = deleted.message
      refute File.exists?(Path.join(root, "readme.txt"))
      assert names(deleted) == ["backup", "snes"]
    end

    test "a directory with anything in it is refused, not emptied", %{root: root} do
      browser =
        Browser.new()
        |> into_root()
        |> select("snes")
        |> Browser.open_actions()
        |> act(:delete)
        |> Browser.overlay_input(:y)

      assert {:error, message} = browser.message
      assert message =~ "not empty"
      assert File.exists?(Path.join(root, "snes/chrono.sfc"))
    end
  end

  describe "the rename editor" do
    setup :tmp_tree

    test "the D-pad edits, A saves, and the column reloads", %{root: root} do
      browser =
        Browser.new()
        |> into_root()
        |> select("readme.txt")
        |> Browser.open_actions()
        |> act(:rename)

      assert {:rename, %{name: "readme.txt", caret: 0}} = browser.overlay

      # Step the first character: r -> s.
      browser = Browser.overlay_input(browser, :down)
      assert {:rename, %{chars: ["s" | _rest]}} = browser.overlay

      browser = Browser.overlay_input(browser, :a)
      assert {:ok, "readme.txt is now seadme.txt."} = browser.message
      assert File.exists?(Path.join(root, "seadme.txt"))
      refute File.exists?(Path.join(root, "readme.txt"))
      assert "seadme.txt" in names(browser)
    end

    test "Y removes the character under the caret" do
      browser =
        Browser.new()
        |> into_root()
        |> select("readme.txt")
        |> Browser.open_actions()
        |> act(:rename)
        |> Browser.overlay_input(:y)

      assert {:rename, %{chars: chars}} = browser.overlay
      assert Enum.join(chars) == "eadme.txt"
    end

    test "stepping at the append position grows the name" do
      browser =
        Browser.new()
        |> into_root()
        |> select("readme.txt")
        |> Browser.open_actions()
        |> act(:rename)

      grown =
        1..20
        |> Enum.reduce(browser, fn _press, acc -> Browser.overlay_input(acc, :right) end)
        |> Browser.overlay_input(:down)

      assert {:rename, %{chars: chars}} = grown.overlay
      assert Enum.join(chars) == "readme.txta"
    end

    test "B cancels and the name is untouched", %{root: root} do
      browser =
        Browser.new()
        |> into_root()
        |> select("readme.txt")
        |> Browser.open_actions()
        |> act(:rename)
        |> Browser.overlay_input(:down)
        |> Browser.overlay_input(:b)

      refute Browser.busy?(browser)
      assert {:ok, "Rename cancelled."} = browser.message
      assert File.exists?(Path.join(root, "readme.txt"))
    end
  end

  describe "reset/1" do
    setup :tmp_tree

    test "goes back to the root column and drops any sheet, but keeps the clipboard" do
      browser =
        Browser.new()
        |> into_root()
        |> select("readme.txt")
        |> Browser.open_actions()
        |> act(:copy)
        |> Browser.open_actions()
        |> Browser.reset()

      assert Browser.depth(browser) == 1
      refute Browser.busy?(browser)
      assert browser.clipboard.name == "readme.txt"
    end
  end

  # -- fixtures -----------------------------------------------------------------

  defp tmp_tree(_context) do
    root = Path.join(System.tmp_dir!(), "browser-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "snes"))
    File.mkdir_p!(Path.join(root, "backup"))
    File.write!(Path.join(root, "snes/chrono.sfc"), "123456789")
    File.write!(Path.join(root, "readme.txt"), "hi")

    Application.put_env(:mayonnaios, :programs, [])

    Application.put_env(:mayonnaios, :file_roots, [
      %{key: "games", path: root, note: "the test card"},
      %{key: "missing", path: Path.join(root, "not-there"), note: "a card that is out"}
    ])

    on_exit(fn -> File.rm_rf(root) end)

    %{root: root}
  end

  # Move the cursor onto the category named `name` and open it.
  defp open(browser, name) do
    %{entries: entries} = hd(browser.levels)
    index = Enum.find_index(entries, &(&1.name == name))
    browser |> Browser.move(index) |> Browser.descend()
  end

  # Into the first configured root's listing.
  defp into_root(browser), do: browser |> open("Files") |> Browser.descend()

  # Put the cursor on the entry named `name` in the focused column.
  defp select(browser, name) do
    %{entries: entries, cursor: cursor} = Browser.focused(browser)
    index = Enum.find_index(entries, &(&1.name == name)) || flunk("no entry #{name}")
    Browser.move(browser, index - cursor)
  end

  # Walk the open sheet to the action with this id and press A on it.
  defp act(browser, id) do
    {:actions, actions, cursor} = browser.overlay
    index = Enum.find_index(actions, &(&1.id == id)) || flunk("no action #{id}")

    browser =
      Enum.reduce(List.duplicate(:down, Integer.mod(index - cursor, length(actions))), browser, fn
        press, acc -> Browser.overlay_input(acc, press)
      end)

    Browser.overlay_input(browser, :a)
  end

  defp names(browser) do
    for node <- List.last(browser.levels).entries, do: node.name
  end
end
