defmodule MayonnaiOS.BrowserTest do
  use ExUnit.Case, async: false

  alias MayonnaiOS.Browser

  # No process and no panel: the browser is a value, and these tests move it
  # the way the Launcher's bindings do and look at what a scene would draw.

  setup do
    # `Programs.list/0` appends a row for every installed pickle, read from
    # disk on every call -- so without this, the Pickles column is however
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

      assert names(browser) == ["Games", "Files", "Pickles", "Settings"]
      assert Browser.depth(browser) == 1
      assert Browser.selected(browser).name == "Games"
    end

    test "the cursor wraps at both ends" do
      browser = Browser.new()

      assert Browser.selected(Browser.move(browser, -1)).name == "Settings"
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
        %{name: "Files", app: MayonnaiOS.FileManager},
        %{name: "Bluetooth controller", app: MayonnaiOS.Controller},
        %{name: "Paint", app: {MayonnaiOS.Pickles.App, "paint"}},
        %{name: "Power off", action: :poweroff}
      ])

      :ok
    end

    test "a path entry is a game" do
      games = open(Browser.new(), "Games")
      assert names(games) == ["RetroArch"]
    end

    test "a pickle's row is a pickle" do
      pickles = open(Browser.new(), "Pickles")
      assert names(pickles) == ["Paint"]
    end

    test "the file manager app is the first row of Files, above the roots" do
      Application.put_env(:mayonnaios, :file_roots, [%{key: "r", path: "/tmp", note: ""}])

      files = open(Browser.new(), "Files")
      assert ["Files", "/tmp"] = names(files)
      assert Browser.selected(files).kind == :program
    end

    test "other apps and the actions land in Settings, verbs last" do
      settings = open(Browser.new(), "Settings")

      assert names(settings) == ["Bluetooth controller", "Diagnostics", "Sleep", "Power off"]
    end

    test "the built-in Settings rows carry the launcher's own verbs" do
      settings = open(Browser.new(), "Settings")

      actions =
        for node <- List.last(settings.levels).entries, do: node.program.action

      assert actions == [nil, :diagnostics, :sleep, :poweroff]
    end
  end

  describe "an empty category" do
    test "says why instead of listing nothing" do
      Application.put_env(:mayonnaios, :programs, [])

      pickles = open(Browser.new(), "Pickles")
      assert names(pickles) == []
      assert List.last(pickles.levels).note == "No pickles installed."
    end
  end

  describe "browsing files" do
    setup do
      root = Path.join(System.tmp_dir!(), "browser-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "snes"))
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

    test "a root opens as a column of its entries", %{root: root} do
      browser = Browser.new() |> open("Files")

      assert Browser.selected(browser).name == root
      browser = Browser.descend(browser)

      # Directories first is Files.list/1's order; the browser keeps it.
      assert names(browser) == ["snes", "readme.txt"]
      assert Browser.trail(browser) == ["RG40XXV", "Files", root]
    end

    test "a directory keeps opening columns, and ascend walks back" do
      browser = Browser.new() |> open("Files") |> Browser.descend() |> Browser.descend()

      assert names(browser) == ["chrono.sfc"]
      assert Browser.depth(browser) == 4

      assert browser |> Browser.ascend() |> names() == ["snes", "readme.txt"]
    end

    test "a file is a leaf: descend does nothing" do
      browser =
        Browser.new() |> open("Files") |> Browser.descend() |> Browser.move(1)

      assert %{kind: :file, name: "readme.txt"} = Browser.selected(browser)
      refute Browser.expandable?(Browser.selected(browser))
      assert Browser.descend(browser) == browser
    end

    test "a root that is not there is a column that says so" do
      browser = Browser.new() |> open("Files") |> Browser.move(1) |> Browser.descend()

      assert names(browser) == []
      assert List.last(browser.levels).note =~ "cannot be read"
    end
  end

  describe "the column-count setting" do
    test "Y cycles 2, 3, 1 and round again" do
      browser = Browser.new()
      assert browser.columns == 2

      browser = Browser.cycle_columns(browser)
      assert browser.columns == 3

      browser = Browser.cycle_columns(browser)
      assert browser.columns == 1

      assert Browser.cycle_columns(browser).columns == 2
    end

    test "visible/1 is the tail of the stack, at most the setting" do
      browser = Browser.new() |> open("Files")

      assert length(Browser.visible(browser)) == 2
      assert length(Browser.visible(%{browser | columns: 1})) == 1

      # Three columns wanted, two levels open: the panel gets what exists.
      assert length(Browser.visible(%{browser | columns: 3})) == 2
    end
  end

  describe "reset/1" do
    test "goes back to the root column but keeps the column setting" do
      browser =
        Browser.new() |> Browser.cycle_columns() |> open("Files") |> Browser.reset()

      assert Browser.depth(browser) == 1
      assert browser.columns == 3
    end
  end

  # Move the cursor onto the category named `name` and open it.
  defp open(browser, name) do
    %{entries: entries} = hd(browser.levels)
    index = Enum.find_index(entries, &(&1.name == name))
    browser |> Browser.move(index) |> Browser.descend()
  end

  defp names(browser) do
    for node <- List.last(browser.levels).entries, do: node.name
  end
end
