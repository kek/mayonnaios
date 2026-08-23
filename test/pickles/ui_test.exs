defmodule MayonnaiOS.Pickles.UiTest do
  use ExUnit.Case, async: false

  alias MayonnaiOS.Pickles.{App, Runner, Store}
  alias MayonnaiOS.Programs
  import MayonnaiOS.PickleFixtures

  # The ui path end to end, with this test process standing where the scene
  # would: attach to a runner, receive frames, and drive buttons through the
  # same App the launcher calls. async: false because App is a named
  # singleton and program_rows reads the global pickles root.

  @counter """
  count = 0

  function on_button(button, pressed)
    if pressed and button == "a" then
      count = count + 1
    end
  end

  function bump()
    count = count + 100
  end

  function on_draw()
    return {
      {kind = "text", x = 40, y = 60, text = "count " .. count, color = "yellow"},
    }
  end
  """

  setup do
    root = Path.join(System.tmp_dir!(), "ui-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    prev = Application.get_env(:mayonnaios, :pickles_root)
    Application.put_env(:mayonnaios, :pickles_root, root)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:mayonnaios, :pickles_root)
        val -> Application.put_env(:mayonnaios, :pickles_root, val)
      end

      File.rm_rf(root)
    end)

    name = "ui#{System.unique_integer([:positive])}"
    tar = pickle_tarball(root, name, @counter, %{"capabilities" => ["ui"]})
    {:ok, _} = Store.install(root, name, tar)

    %{root: root, name: name}
  end

  defp start_runner(name, root) do
    start_supervised!({Runner, name: name, root: root}, id: name)
  end

  test "attach gets a frame, buttons and actions get fresh ones", %{root: root, name: name} do
    start_runner(name, root)
    pid = Runner.whereis(name)

    send(pid, {:ui_attach, self()})
    assert_receive {:pickle_frame, %{ops: [{:text, %{text: "count 0", color: :yellow}}]}}

    # The physical A button, as the launcher forwards it and App translates.
    send(pid, {:ui_button, "a", true})
    assert_receive {:pickle_frame, %{ops: [{:text, %{text: "count 1"}}]}}

    # A release reaches the script too, and changes nothing in this one.
    send(pid, {:ui_button, "a", false})
    assert_receive {:pickle_frame, %{ops: [{:text, %{text: "count 1"}}]}}

    # An action call over the web repaints the face as well.
    assert {:ok, _} = Runner.call(name, "bump", [])
    assert_receive {:pickle_frame, %{ops: [{:text, %{text: "count 101"}}]}}
  end

  test "a script with no on_draw is a readable notice, not silence", %{root: root} do
    name = "noface#{System.unique_integer([:positive])}"
    tar = pickle_tarball(root, name, "x = 1", %{"capabilities" => ["ui"]})
    {:ok, _} = Store.install(root, name, tar)
    start_runner(name, root)

    send(Runner.whereis(name), {:ui_attach, self()})
    assert_receive {:pickle_frame_error, "the script defines no on_draw()"}
  end

  test "the App adapter: start attaches, input translates, stop detaches", %{name: name} do
    assert {:ok, _pid} = App.start(name)
    assert App.current() == name
    assert App.scene() == MayonnaiOS.Scene.Pickle

    # Stand in for the scene.
    send(Runner.whereis(name), {:ui_attach, self()})
    assert_receive {:pickle_frame, %{ops: [{:text, %{text: "count 0"}}]}}

    # evdev truth: :btn_b is the plastic A. Menu is dropped, autorepeat (2)
    # is dropped.
    App.input([{:ev_key, :btn_b, 1}, {:ev_key, :btn_mode, 1}, {:ev_key, :btn_b, 2}])
    assert_receive {:pickle_frame, %{ops: [{:text, %{text: "count 1"}}]}}
    refute_receive {:pickle_frame, _}, 200

    # Menu: the face comes off, the pickle keeps running.
    assert :ok = App.stop()
    assert App.current() == nil
    assert Runner.whereis(name) != nil
  end

  test "ui pickles appear as launcher rows, others do not", %{root: root, name: name} do
    plain = "plain#{System.unique_integer([:positive])}"
    tar = pickle_tarball(root, plain, "x = 1")
    {:ok, _} = Store.install(root, plain, tar)

    rows = Programs.list()
    row = Enum.find(rows, &(&1.name == name))

    assert %{app: {App, ^name}, installed?: true} = row
    refute Enum.any?(rows, &(&1.name == plain))
  end

  test "mayo.ui.redraw and mayo.ui.size are there for the asking", %{root: root} do
    name = "redraw#{System.unique_integer([:positive])}"

    lua = """
    label = "before"

    function on_draw()
      return {{kind = "text", x = 1, y = 2, text = label .. " " .. mayo.ui.width .. "x" .. mayo.ui.height}}
    end

    function rename(to)
      label = to
      mayo.ui.redraw()
    end
    """

    tar = pickle_tarball(root, name, lua, %{"capabilities" => ["ui"]})
    {:ok, _} = Store.install(root, name, tar)
    start_runner(name, root)

    send(Runner.whereis(name), {:ui_attach, self()})
    assert_receive {:pickle_frame, %{ops: [{:text, %{text: "before 640x480"}}]}}
  end
end
