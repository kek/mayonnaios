defmodule MayonnaiOS.Moonlight.AppTest do
  # Not async: the app is a named process, and the config path it reads is
  # application environment.
  use ExUnit.Case, async: false

  alias MayonnaiOS.Moonlight
  alias MayonnaiOS.Moonlight.App
  alias MayonnaiOS.Scene.Moonlight, as: Scene

  # The launcher's vocabulary; see `MayonnaiOS.Launcher`'s moduledoc for why
  # the atom named "b" is the button printed A.
  @accept :btn_b
  @remove :btn_x
  @menu :btn_mode
  @up :btn_dpad_up
  @down :btn_dpad_down
  @left :btn_dpad_left
  @right :btn_dpad_right

  setup do
    base = Path.join(System.tmp_dir!(), "moonlight-app-#{System.unique_integer([:positive])}")
    config = Path.join([base, "config", "moonlight.conf"])
    File.mkdir_p!(base)

    prev = %{
      bundle_root: Application.get_env(:mayonnaios, :bundle_root),
      moonlight_config: Application.get_env(:mayonnaios, :moonlight_config)
    }

    Application.put_env(:mayonnaios, :bundle_root, Path.join(base, "bundles"))
    Application.put_env(:mayonnaios, :moonlight_config, config)

    on_exit(fn ->
      App.stop()
      File.rm_rf(base)

      Enum.each(prev, fn
        {k, nil} -> Application.delete_env(:mayonnaios, k)
        {k, v} -> Application.put_env(:mayonnaios, k, v)
      end)
    end)

    %{base: base, config: config}
  end

  # A press is a whole evdev report, the way the launcher forwards one, and
  # `input/1` is a cast -- so every helper here reads the snapshot afterwards,
  # which is the call that makes the cast have landed.
  defp press(key) do
    App.input([{:ev_key, key, 1}])
    App.snapshot()
  end

  # `1..times//1` rather than `1..times`: a descending range is still a range,
  # so `1..0` would press twice where nothing should be pressed at all.
  defp press(key, times) do
    Enum.reduce(1..times//1, App.snapshot(), fn _n, _acc -> press(key) end)
  end

  defp start! do
    {:ok, _pid} = App.start()
    App.snapshot()
  end

  # The index of a row by its id, so a test says what it means rather than
  # counting rows that a later field would renumber.
  defp row(id), do: Enum.find_index(App.rows(), &(&1.id == id))

  defp go_to(id) do
    press(@down, row(id))
  end

  describe "starting" do
    test "opens on the defaults when nothing has been saved" do
      snapshot = start!()

      assert snapshot.settings == Moonlight.defaults()
      assert snapshot.source == :defaults
      assert snapshot.cursor == 0
      assert snapshot.editor == nil
      refute snapshot.unsaved?
      refute snapshot.installed?
    end

    test "opens on the saved file when there is one", %{config: config} do
      File.mkdir_p!(Path.dirname(config))
      File.write!(config, "address = saved.lan\nfps = 60\n")

      snapshot = start!()

      assert snapshot.settings.address == "saved.lan"
      assert snapshot.settings.fps == "60"
      assert snapshot.source == :file
    end

    test "starting twice is the same process" do
      {:ok, first} = App.start()
      {:ok, second} = App.start()

      assert first == second
    end

    test "snapshot and watch say so when it is not running" do
      assert App.snapshot() == :stopped
      assert App.watch(self()) == :stopped
    end
  end

  describe "moving between rows" do
    test "down and up wrap" do
      start!()
      last = length(App.rows()) - 1

      assert press(@up).cursor == last
      assert press(@down).cursor == 0
    end

    test "the last row is the one that saves" do
      start!()

      assert List.last(App.rows()).id == :save
    end
  end

  describe "choice rows" do
    test "right and left change the value" do
      start!()
      go_to(:fps)

      assert press(@right).settings.fps == "60"
      assert press(@right).settings.fps == "30"
      assert press(@left).settings.fps == "60"
    end

    test "changing one is an unsaved change" do
      start!()
      go_to(:bitrate)

      assert press(@right).unsaved?
    end

    test "a value the screen does not offer is stepped away from, not snapped to", %{
      config: config
    } do
      File.mkdir_p!(Path.dirname(config))
      File.write!(config, "width = 1600\nheight = 900\n")
      start!()
      go_to(:resolution)

      assert App.snapshot().settings.resolution == "1600x900"
      # It sits at the end of the list, so one step back lands on the last
      # value the screen does offer.
      assert press(@left).settings.resolution == "1920x1080"
    end

    test "left and right do nothing on a text row" do
      start!()
      go_to(:address)

      assert press(@right).settings.address == ""
      assert press(@left).settings.address == ""
    end
  end

  describe "the editor" do
    test "A opens it on a text row, with the caret at the end", %{config: config} do
      File.mkdir_p!(Path.dirname(config))
      File.write!(config, "address = 10.0\n")
      start!()
      go_to(:address)

      snapshot = press(@accept)

      assert snapshot.editor.id == :address
      assert snapshot.editor.chars == ["1", "0", ".", "0"]
      assert snapshot.editor.caret == 4
    end

    test "down at the end puts a character there and then steps it" do
      start!()
      go_to(:address)
      press(@accept)

      assert press(@down).editor.chars == ["0"]
      assert press(@down).editor.chars == ["1"]
    end

    test "up from nothing starts at the other end of the alphabet" do
      start!()
      go_to(:address)
      press(@accept)

      # The first press has no character to step from, so it puts the first
      # one of the alphabet down; the second steps back from it.
      assert press(@up).editor.chars == ["0"]
      assert press(@up).editor.chars == [" "]
    end

    test "left and right move the caret" do
      start!()
      go_to(:address)
      press(@accept)
      press(@down, 2)

      assert press(@left).editor.caret == 0
      assert press(@right).editor.caret == 1
      # One past the end is a real position: it is where a character is added.
      assert press(@right).editor.caret == 1
    end

    test "Y removes the character under the caret" do
      start!()
      go_to(:address)
      press(@accept)
      press(@down)
      press(@down)
      press(@left)

      assert press(@remove).editor.chars == []
    end

    test "Y on an empty value does nothing" do
      start!()
      go_to(:address)
      press(@accept)

      assert press(@remove).editor.chars == []
    end

    test "A keeps what was typed and closes the editor" do
      start!()
      go_to(:address)
      press(@accept)
      press(@down)

      snapshot = press(@accept)

      assert snapshot.editor == nil
      assert snapshot.settings.address == "0"
      assert snapshot.unsaved?
    end

    test "the row list's bindings are off while it is open" do
      start!()
      go_to(:app)
      press(@accept)

      # Up and down belong to the character picker now, so neither moves the
      # cursor off the row being edited -- which is the property that keeps a
      # D-pad press from meaning two things at once.
      assert press(@up).cursor == row(:app)
      assert press(@down).cursor == row(:app)
    end
  end

  describe "saving" do
    test "A on the last row writes the file", %{config: config} do
      start!()
      go_to(:address)
      press(@accept)
      press(@down)
      press(@accept)
      go_to(:save)

      snapshot = press(@accept)

      assert {:ok, _words} = snapshot.message
      refute snapshot.unsaved?
      assert snapshot.source == :file
      assert File.read!(config) =~ "address = 0"
    end

    test "a write that cannot happen is a message, not a crash", %{base: base} do
      blocked = Path.join(base, "blocked")
      File.write!(blocked, "not a directory")
      Application.put_env(:mayonnaios, :moonlight_config, Path.join([blocked, "x", "m.conf"]))

      start!()
      go_to(:save)

      assert {:error, words} = press(@accept).message
      assert words =~ "Could not write"
      assert Process.whereis(App) != nil
    end

    test "moving the cursor clears the last message" do
      start!()
      go_to(:save)
      press(@accept)

      assert press(@up).message == nil
    end
  end

  describe "the launcher's own buttons" do
    test "Menu changes nothing here -- the launcher stops the app on it" do
      before = start!()

      assert press(@menu) == before
    end
  end

  describe "watchers" do
    test "are told when something changes and not when nothing does" do
      start!()
      App.watch(self())

      App.input([{:ev_key, @down, 1}])
      assert_receive {:moonlight_app, %{cursor: 1}}

      # A key nothing is bound to produces no snapshot change and so no push.
      App.input([{:ev_key, :btn_start, 1}])
      refute_receive {:moonlight_app, _snapshot}, 50
    end
  end

  describe "the scene" do
    # graph/1 is the tested surface: no viewport, no driver, no framebuffer.
    # Same helper the other scene tests use.
    defp texts(graph) do
      Scenic.Graph.reduce(graph, [], fn
        %Scenic.Primitive{module: Scenic.Primitive.Text, data: data}, acc -> [data | acc]
        _primitive, acc -> acc
      end)
    end

    defp snapshot(overrides \\ %{}) do
      Map.merge(
        %{
          settings: Moonlight.defaults(),
          source: :defaults,
          installed?: true,
          path: "/root/.config/moonlight/moonlight.conf",
          cursor: 0,
          editor: nil,
          message: nil,
          unsaved?: false
        },
        overrides
      )
    end

    test "not running" do
      assert Enum.member?(texts(Scene.graph(:stopped)), "Not running")
    end

    test "every row is drawn, with its value" do
      texts = texts(Scene.graph(snapshot()))

      assert Enum.member?(texts, "Host address")
      assert Enum.member?(texts, "not set")
      assert Enum.member?(texts, "Resolution")
      assert Enum.member?(texts, "1280x720")
      assert Enum.member?(texts, "30 fps")
      assert Enum.member?(texts, "5000 kbps")
      assert Enum.member?(texts, "h264")
      assert Enum.member?(texts, "Save")
    end

    test "a missing bundle is said before anything else" do
      texts = texts(Scene.graph(snapshot(%{installed?: false})))

      assert Enum.any?(texts, &String.contains?(&1, "not installed"))
    end

    test "unsaved changes are on the panel, not in a footnote" do
      texts = texts(Scene.graph(snapshot(%{unsaved?: true})))

      assert Enum.member?(texts, "Unsaved changes.")
      assert Enum.any?(texts, &String.contains?(&1, "A writes the changes"))
    end

    test "a saved file is named" do
      texts = texts(Scene.graph(snapshot(%{source: :file, path: "/tmp/m.conf"})))

      assert Enum.member?(texts, "/tmp/m.conf")
    end

    test "an unset address is said out loud" do
      assert Enum.any?(
               texts(Scene.graph(snapshot())),
               &String.contains?(&1, "cannot start without a host address")
             )
    end

    test "a set address takes that line away" do
      settings = Map.put(Moonlight.defaults(), :address, "10.0.0.5")

      refute Enum.any?(
               texts(Scene.graph(snapshot(%{settings: settings}))),
               &String.contains?(&1, "cannot start without")
             )
    end

    test "a failed write is red words on the panel" do
      texts =
        texts(Scene.graph(snapshot(%{message: {:error, "Could not write /x: no permission"}})))

      assert Enum.member?(texts, "Could not write /x: no permission")
    end

    test "the selected row's note is the manual" do
      texts = texts(Scene.graph(snapshot(%{cursor: 3})))

      assert Enum.any?(texts, &String.contains?(&1, "Lower this first"))
    end

    test "the footer says what the buttons do on this row" do
      choice = texts(Scene.graph(snapshot(%{cursor: 1})))
      text_row = texts(Scene.graph(snapshot(%{cursor: 0})))
      save = texts(Scene.graph(snapshot(%{cursor: length(App.rows()) - 1})))

      assert Enum.any?(choice, &String.contains?(&1, "Left and right change it"))
      assert Enum.any?(text_row, &String.contains?(&1, "A edits it"))
      assert Enum.any?(save, &String.contains?(&1, "A saves"))
    end

    test "the editor takes the panel and the rows go" do
      editor = %{id: :address, chars: ["1", "0"], caret: 2}
      texts = texts(Scene.graph(snapshot(%{editor: editor})))

      assert Enum.member?(texts, "Host address")
      refute Enum.member?(texts, "Resolution")
      assert Enum.member?(texts, "1")
      assert Enum.member?(texts, "0")
      assert Enum.any?(texts, &String.contains?(&1, "Y removes it"))
    end

    test "a hostname longer than the row is cut rather than drawn off the panel" do
      long = String.duplicate("a", 80) <> ".lan"
      settings = Map.put(Moonlight.defaults(), :address, long)
      texts = texts(Scene.graph(snapshot(%{settings: settings})))

      refute Enum.member?(texts, long)
      assert Enum.any?(texts, &(String.starts_with?(&1, "aaa") and String.ends_with?(&1, "…")))
    end

    test "a long failure keeps its reason rather than its path" do
      words =
        "Could not write /root/.config/moonlight/moonlight.conf: that filesystem is read-only"

      texts = texts(Scene.graph(snapshot(%{message: {:error, words}})))

      refute Enum.member?(texts, words)
      assert Enum.any?(texts, &String.ends_with?(&1, "that filesystem is read-only"))
    end

    test "nothing is drawn over the shared top bar" do
      graph = Scene.graph(snapshot())

      Scenic.Graph.reduce(graph, nil, fn
        %Scenic.Primitive{module: Scenic.Primitive.Text, transforms: %{translate: {_x, y}}},
        acc ->
          assert y >= Scene.status_bar()
          acc

        _primitive, acc ->
          acc
      end)
    end
  end
end
