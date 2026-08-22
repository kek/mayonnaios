defmodule MayonnaiOS.FileManagerTest do
  # Not async: the app is a named process and the roots are application
  # environment, both of which are one global.
  use ExUnit.Case, async: false

  alias MayonnaiOS.FileManager
  alias MayonnaiOS.Scene.FileManager, as: Scene

  # The buttons as InputEvent names them, not as the shell prints them. Spelled
  # out here rather than reused from the module under test: if these ever
  # disagree, the test is the thing that should notice, and a test that imports
  # its expectations from the code cannot.
  #
  #   shell A = 305 BTN_EAST  -> :btn_b
  #   shell B = 304 BTN_SOUTH -> :btn_a
  #   shell Y = 307           -> :btn_x
  @a :btn_b
  @b :btn_a
  @y :btn_x
  @up :btn_dpad_up
  @down :btn_dpad_down
  @left :btn_dpad_left
  @right :btn_dpad_right
  @menu :btn_mode

  setup do
    id = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "fm-#{id}")
    card = Path.join(System.tmp_dir!(), "fm-card-#{id}")

    File.mkdir_p!(Path.join(root, "snes"))
    File.mkdir_p!(Path.join(root, "backup"))
    File.mkdir_p!(card)
    File.write!(Path.join([root, "snes", "chrono.sfc"]), "rom bytes")
    File.write!(Path.join([root, "snes", "zelda.sfc"]), "zelda")
    File.write!(Path.join(root, "readme.txt"), "hello")

    Application.put_env(:mayonnaios, :file_roots, [
      %{key: "internal", path: root, note: "games, and where uploads land"},
      %{key: "card", path: card, note: "the other card"}
    ])

    {:ok, _pid} = FileManager.start()

    on_exit(fn ->
      FileManager.stop()
      Application.delete_env(:mayonnaios, :file_roots)
      File.rm_rf(root)
      File.rm_rf(card)
    end)

    %{root: root, card: card}
  end

  # input/1 is a cast and snapshot/0 is a call, so the call is ordered behind
  # the press and no test has to sleep.
  defp press(key, value \\ 1) do
    FileManager.input([{:ev_key, key, value}])
    FileManager.snapshot()
  end

  defp names(%{entries: entries}), do: Enum.map(entries, & &1.name)
  defp labels(%{actions: actions}), do: Enum.map(actions, & &1.label)

  defp selected(%{entries: entries, cursor: cursor}) do
    case Enum.at(entries, cursor) do
      nil -> nil
      entry -> entry.name
    end
  end

  # B is the way back out of anything, so it is also the way back to a known
  # place before the next step of a test.
  defp home do
    Enum.reduce_while(1..8, FileManager.snapshot(), fn _step, snapshot ->
      if snapshot.view == :places, do: {:halt, snapshot}, else: {:cont, press(@b)}
    end)
  end

  # Open a directory by name from the first root.
  defp open(name) do
    home()
    press(@a)
    to(name)
    press(@a)
  end

  defp to(name) do
    snapshot =
      Enum.reduce_while(1..60, FileManager.snapshot(), fn _step, snapshot ->
        if selected(snapshot) == name, do: {:halt, snapshot}, else: {:cont, press(@down)}
      end)

    assert selected(snapshot) == name, "never found #{name} in #{inspect(names(snapshot))}"
    snapshot
  end

  describe "opening" do
    test "starts on the list of places, which is the only entry point" do
      snapshot = FileManager.snapshot()
      assert snapshot.view == :places
      assert Enum.map(snapshot.places, & &1.key) == ["internal", "card"]
    end

    test "A opens a place and lists it, directories first", %{root: root} do
      snapshot = press(@a)

      assert snapshot.view == :browse
      assert snapshot.dir == root
      assert names(snapshot) == ["backup", "snes", "readme.txt"]
    end

    test "the free space shown is for the filesystem the directory is on" do
      snapshot = press(@a)
      assert %{free: free, device: device} = snapshot.space
      assert free > 0
      assert is_binary(device)
    end
  end

  describe "the D-pad" do
    test "down moves and up wraps round the ends" do
      press(@a)
      assert selected(press(@down)) == "snes"
      assert selected(press(@down)) == "readme.txt"
      assert selected(press(@down)) == "backup"
      assert selected(press(@up)) == "readme.txt"
    end

    test "autorepeat moves the cursor, unlike the launcher menu" do
      # The launcher drops autorepeat because each move re-roots the viewport.
      # Here a move is a graph push, so holding a direction may scroll -- may,
      # because whether this board's gpio-keys emits autorepeat at all has not
      # been checked on the device.
      press(@a)
      assert press(@down, 2).cursor == 1
    end

    test "autorepeat on a face button does nothing, so a held A cannot repeat" do
      snapshot = press(@a, 2)
      assert snapshot.view == :places
    end

    test "left and right page, and clamp rather than wrap", %{root: root} do
      for index <- 1..30, do: File.write!(Path.join(root, "rom-#{index}.sfc"), "x")

      snapshot = press(@a)
      # Two directories, thirty ROMs and the readme.
      assert length(snapshot.entries) == 33

      assert press(@right).cursor == 10
      assert press(@right).cursor == 20
      assert press(@right).cursor == 30

      # Clamped at the end rather than wrapped: a page that wrapped would read
      # as the app having lost its place in a long directory.
      assert press(@right).cursor == 32
      assert press(@right).cursor == 32

      assert press(@left).cursor == 22
      assert press(@left).cursor == 12
      assert press(@left).cursor == 2
      assert press(@left).cursor == 0
    end
  end

  describe "walking the tree" do
    test "A descends into a directory and B comes back to it" do
      open("snes")
      snapshot = FileManager.snapshot()
      assert names(snapshot) == ["chrono.sfc", "zelda.sfc"]

      # Back up, and the cursor is on the directory just left rather than at
      # the top of the parent.
      snapshot = press(@b)
      assert snapshot.view == :browse
      assert selected(snapshot) == "snes"
    end

    test "B at the top of a root goes back to the places, not out of it" do
      press(@a)
      snapshot = press(@b)
      assert snapshot.view == :places
      # And again does nothing: there is nowhere above the roots.
      assert press(@b).view == :places
    end

    test "Menu is the launcher's and changes nothing here" do
      before = press(@a)
      assert press(@menu) == before
    end

    test "a directory that is not there is reported rather than raising", %{root: root} do
      press(@a)
      to("snes")

      # Removed behind the app's back, which is the case that must not crash:
      # the listing on screen is a moment old, and the web upload page and a
      # shell over SSH can both change the disk under it.
      File.rm_rf!(Path.join(root, "snes"))
      snapshot = press(@a)

      refute snapshot.readable?
      assert {:error, _text} = snapshot.message
      assert snapshot.entries == []
    end
  end

  describe "the actions sheet" do
    test "Y offers the verbs for a file" do
      open("snes")
      snapshot = press(@y)

      assert snapshot.view == :actions

      assert labels(snapshot) == [
               "Copy chrono.sfc",
               "Move chrono.sfc",
               "Rename chrono.sfc",
               "Delete chrono.sfc"
             ]
    end

    test "a directory is not offered a copy it cannot do" do
      press(@a)
      snapshot = press(@y)

      assert labels(snapshot) == ["Move backup", "Rename backup", "Delete backup"]
    end

    test "A on a file opens the same sheet, because there is nothing to open" do
      open("snes")
      assert press(@a).view == :actions
    end

    test "B leaves the sheet without doing anything" do
      open("snes")
      press(@y)
      snapshot = press(@b)

      assert snapshot.view == :browse
      assert snapshot.actions == []
    end
  end

  describe "deleting" do
    test "choosing Delete deletes nothing; it asks", %{root: root} do
      open("snes")
      press(@y)
      # Copy, Move, Rename, Delete
      press(@down)
      press(@down)
      press(@down)
      snapshot = press(@a)

      assert snapshot.view == :confirm
      assert snapshot.pending.entry.name == "chrono.sfc"
      assert File.exists?(Path.join([root, "snes", "chrono.sfc"]))
    end

    test "A on the confirmation cancels, because A is the button that got here", ctx do
      %{root: root} = ctx
      confirm_delete_of("chrono.sfc")

      snapshot = press(@a)

      assert snapshot.view == :browse
      assert snapshot.message == {:ok, "Nothing was deleted."}
      assert File.exists?(Path.join([root, "snes", "chrono.sfc"]))
    end

    test "B cancels too, and so does a direction", %{root: root} do
      confirm_delete_of("chrono.sfc")
      assert press(@b).view == :browse
      assert File.exists?(Path.join([root, "snes", "chrono.sfc"]))

      confirm_delete_of("chrono.sfc")
      assert press(@down).view == :browse
      assert File.exists?(Path.join([root, "snes", "chrono.sfc"]))
    end

    test "Y deletes it, and the listing is re-read", %{root: root} do
      confirm_delete_of("chrono.sfc")

      snapshot = press(@y)

      assert snapshot.view == :browse
      assert snapshot.message == {:ok, "chrono.sfc deleted."}
      refute File.exists?(Path.join([root, "snes", "chrono.sfc"]))
      assert names(snapshot) == ["zelda.sfc"]
    end

    test "a directory with something in it is refused, with the reason", ctx do
      %{root: root} = ctx
      press(@a)
      to("snes")
      press(@y)
      press(@down)
      press(@down)
      snapshot = press(@a)
      assert snapshot.view == :confirm

      snapshot = press(@y)

      assert {:error, message} = snapshot.message
      assert message =~ "not empty"
      assert File.exists?(Path.join([root, "snes", "chrono.sfc"]))
    end

    defp confirm_delete_of(name) do
      open("snes")
      to(name)
      press(@y)
      snapshot = FileManager.snapshot()
      index = Enum.find_index(snapshot.actions, &(&1.id == :delete))
      for _step <- 1..index, do: press(@down)
      snapshot = press(@a)
      assert snapshot.view == :confirm
      snapshot
    end
  end

  describe "copying and moving" do
    test "copy holds the file, and pasting puts it somewhere else", ctx do
      %{root: root} = ctx
      open("snes")
      choose(:copy)

      snapshot = FileManager.snapshot()
      assert snapshot.clipboard.name == "chrono.sfc"
      assert snapshot.view == :browse

      press(@b)
      to("backup")
      press(@a)
      snapshot = paste()

      assert snapshot.message == {:ok, "chrono.sfc copied here."}
      assert File.read!(Path.join([root, "backup", "chrono.sfc"])) == "rom bytes"
      # Still there, so this really was a copy.
      assert File.exists?(Path.join([root, "snes", "chrono.sfc"]))
      # And still held, so the same ROM can go on both cards.
      assert FileManager.snapshot().clipboard != nil
    end

    test "move takes it, and clears the clipboard", %{root: root} do
      open("snes")
      choose(:move)

      press(@b)
      to("backup")
      press(@a)
      snapshot = paste()

      assert snapshot.message == {:ok, "chrono.sfc moved here."}
      assert File.exists?(Path.join([root, "backup", "chrono.sfc"]))
      refute File.exists?(Path.join([root, "snes", "chrono.sfc"]))
      assert snapshot.clipboard == nil
    end

    test "pasting onto a name that is taken is refused, not an overwrite", ctx do
      %{root: root} = ctx
      File.write!(Path.join([root, "backup", "chrono.sfc"]), "someone's save")

      open("snes")
      choose(:copy)
      press(@b)
      to("backup")
      press(@a)
      snapshot = paste()

      assert {:error, message} = snapshot.message
      assert message =~ "already there"
      assert File.read!(Path.join([root, "backup", "chrono.sfc"])) == "someone's save"
    end

    test "the clipboard can be forgotten" do
      open("snes")
      choose(:copy)
      press(@y)
      snapshot = FileManager.snapshot()
      index = Enum.find_index(snapshot.actions, &(&1.id == :forget))
      for _step <- 1..index, do: press(@down)
      snapshot = press(@a)

      assert snapshot.clipboard == nil
    end

    defp choose(id) do
      press(@y)
      snapshot = FileManager.snapshot()
      index = Enum.find_index(snapshot.actions, &(&1.id == id))
      for _step <- 1..index//1, do: press(@down)
      press(@a)
    end

    defp paste do
      press(@y)
      snapshot = FileManager.snapshot()
      assert hd(snapshot.actions).id == :paste
      press(@a)
    end
  end

  describe "renaming" do
    test "the editor starts on the current name" do
      open("snes")
      choose(:rename)
      snapshot = FileManager.snapshot()

      assert snapshot.view == :rename
      assert Enum.join(snapshot.rename.chars) == "chrono.sfc"
      assert snapshot.rename.caret == 0
    end

    test "up changes the character under the caret, and A saves it", %{root: root} do
      open("snes")
      choose(:rename)

      # 'c' -> 'd', then save.
      snapshot = press(@down)
      assert Enum.join(snapshot.rename.chars) == "dhrono.sfc"

      snapshot = press(@a)
      assert snapshot.view == :browse
      assert snapshot.message == {:ok, "chrono.sfc is now dhrono.sfc."}
      assert File.exists?(Path.join([root, "snes", "dhrono.sfc"]))
    end

    test "the caret moves and stops at both ends" do
      open("snes")
      choose(:rename)

      assert press(@left).rename.caret == 0
      assert press(@right).rename.caret == 1

      # Ten characters, so caret 10 is the append slot and there is nothing
      # past it.
      snapshot = Enum.reduce(1..20, nil, fn _step, _acc -> press(@right) end)
      assert snapshot.rename.caret == 10
    end

    test "up on the append slot adds a character and stays on it" do
      open("snes")
      choose(:rename)
      for _step <- 1..10, do: press(@right)

      snapshot = press(@up)
      assert Enum.join(snapshot.rename.chars) == "chrono.sfca"
      assert snapshot.rename.caret == 10

      # And stepping again changes that character rather than adding another.
      snapshot = press(@up)
      assert String.length(Enum.join(snapshot.rename.chars)) == 11
    end

    test "Y removes the character under the caret" do
      open("snes")
      choose(:rename)
      snapshot = press(@y)

      assert Enum.join(snapshot.rename.chars) == "hrono.sfc"
    end

    test "an empty name is refused and the editor stays open" do
      open("snes")
      choose(:rename)
      for _step <- 1..12, do: press(@y)

      snapshot = press(@a)

      assert snapshot.view == :rename
      assert {:error, message} = snapshot.message
      assert message =~ "not allowed"
    end

    test "B cancels and the file keeps its name", %{root: root} do
      open("snes")
      choose(:rename)
      press(@down)
      snapshot = press(@b)

      assert snapshot.view == :browse
      assert File.exists?(Path.join([root, "snes", "chrono.sfc"]))
    end

    test "the picker cannot type a separator, so a rename cannot become a move" do
      # The boundary in MayonnaiOS.Files rejects it anyway -- that is tested
      # there -- and the editor cannot even produce it. Both, because the
      # second is a UI decision that could be changed by someone who had not
      # read the first.
      open("snes")
      choose(:rename)
      snapshot = FileManager.snapshot()

      typed =
        Enum.reduce(1..80, snapshot, fn _step, _acc -> press(@up) end)
        |> Map.fetch!(:rename)
        |> Map.fetch!(:chars)
        |> Enum.join()

      refute String.contains?(typed, "/")
      refute String.contains?(typed, "\\")
    end
  end

  describe "symlinks" do
    test "are shown as links, and deleting one leaves the target", %{root: root} do
      target = Path.join(root, "readme.txt")
      File.ln_s!(target, Path.join(root, "link.txt"))

      press(@a)
      snapshot = to("link.txt")
      entry = Enum.at(snapshot.entries, snapshot.cursor)
      assert entry.link == target

      press(@y)
      snapshot = FileManager.snapshot()
      # No copy for a link: copying through one is the one way a read could
      # leave the roots.
      refute Enum.any?(snapshot.actions, &(&1.id == :copy))

      index = Enum.find_index(snapshot.actions, &(&1.id == :delete))
      for _step <- 1..index, do: press(@down)
      press(@a)
      press(@y)

      refute File.exists?(Path.join(root, "link.txt"))
      assert File.read!(target) == "hello"
    end
  end

  describe "the panel" do
    test "nothing is drawn in the strip reserved for the shared top bar" do
      # The status bar is another agent's job. This asserts only that this
      # screen leaves room for it, in every view, so that arriving later is a
      # matter of drawing rather than of re-laying-out this one.
      for snapshot <- every_view() do
        graph = Scene.graph(snapshot)

        for {y, primitive} <- placements(graph) do
          assert y >= Scene.status_bar(),
                 "#{inspect(primitive)} is at y=#{y}, inside the top #{Scene.status_bar()} px"
        end
      end
    end

    test "the confirmation says the whole path and which button does it" do
      confirm_delete_of("chrono.sfc")
      words = texts(Scene.graph(FileManager.snapshot()))

      assert Enum.any?(words, &String.ends_with?(&1, "snes/chrono.sfc"))
      assert "Y deletes it." in words
      assert Enum.any?(words, &String.contains?(&1, "no undo"))
    end

    test "an empty directory says so rather than looking broken", %{root: root} do
      press(@a)
      to("backup")
      press(@a)

      assert "Empty." in texts(Scene.graph(FileManager.snapshot()))
      assert File.dir?(Path.join(root, "backup"))
    end

    test "a long listing is windowed and says where in it you are", %{root: root} do
      for index <- 1..40, do: File.write!(Path.join(root, "rom-#{index}.sfc"), "x")

      press(@a)
      for _step <- 1..30, do: press(@down)

      words = texts(Scene.graph(FileManager.snapshot()))
      assert Enum.any?(words, &String.match?(&1, ~r/^\d+ of 43$/))
    end

    test "the places screen names each root and what it is for" do
      words = texts(Scene.graph(FileManager.snapshot()))
      assert "games, and where uploads land" in words
    end

    test "every view builds a graph, including the app not running" do
      assert %Scenic.Graph{} = Scene.graph(:stopped)
      assert %Scenic.Graph{} = Scene.graph(:stopped, :enoent)

      for snapshot <- every_view() do
        assert %Scenic.Graph{} = Scene.graph(snapshot), "#{snapshot.view} did not build"
      end
    end

    test "a snapshot from a state the app cannot reach still builds" do
      # The scene is its own process reading a snapshot, so it must not crash
      # on one that does not make sense to it.
      assert %Scenic.Graph{} = Scene.graph(%{FileManager.snapshot() | view: :confirm})
      assert %Scenic.Graph{} = Scene.graph(%{FileManager.snapshot() | view: :nonsense})
    end

    # One snapshot per view, taken from the app rather than written out here,
    # so a view that changes shape cannot leave the rendering test passing
    # against a shape nothing produces.
    defp every_view do
      places = FileManager.snapshot()
      browse = press(@a)

      press(@y)
      actions = FileManager.snapshot()
      press(@b)

      confirm = confirm_delete_of("chrono.sfc")
      press(@b)

      open("snes")
      choose(:rename)
      rename = FileManager.snapshot()
      press(@b)

      [places, browse, actions, confirm, rename]
    end

    defp texts(graph) do
      Scenic.Graph.reduce(graph, [], fn
        %Scenic.Primitive{module: Scenic.Primitive.Text, data: data}, acc -> [data | acc]
        _primitive, acc -> acc
      end)
    end

    # Every primitive's y, except the full-screen background: the status bar
    # will paint over that, and a screen with no background is not a screen.
    defp placements(graph) do
      Scenic.Graph.reduce(graph, [], fn
        %Scenic.Primitive{data: {640, 480}}, acc ->
          acc

        %Scenic.Primitive{} = primitive, acc ->
          case get_in(primitive.transforms, [:translate]) do
            {_x, y} -> [{y, primitive.module} | acc]
            _none -> acc
          end
      end)
    end
  end
end
