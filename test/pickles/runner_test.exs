defmodule MayonnaiOS.Pickles.RunnerTest do
  use ExUnit.Case, async: true

  alias MayonnaiOS.Pickles.{Runner, Store}
  import MayonnaiOS.PickleFixtures

  # The Registry these register in comes from the application's own
  # supervision tree -- the same one the device uses -- so names must be
  # unique across concurrently running tests.

  setup do
    root = Path.join(System.tmp_dir!(), "runner-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, name: "t#{System.unique_integer([:positive])}"}
  end

  defp install_and_start(root, name, lua, fields \\ %{}) do
    tar = pickle_tarball(root, name, lua, fields)
    {:ok, _} = Store.install(root, name, tar)
    start_supervised!({Runner, name: name, root: root}, id: name)
  end

  test "runs the chunk, calls on_start, and answers actions", %{root: root, name: name} do
    lua = """
    count = 0

    function on_start()
      mayo.log("booted")
      count = 10
    end

    function bump(by)
      count = count + by
      return count
    end
    """

    install_and_start(root, name, lua)

    assert {:ok, [15]} = Runner.call(name, "bump", [5])
    assert {:ok, [20]} = Runner.call(name, "bump", [5])

    info = Runner.info(name)
    assert info.status == :running
    assert Enum.any?(info.log, &(&1.msg == "booted"))
  end

  test "a broken script is a visible error, not a dead process", %{root: root, name: name} do
    install_and_start(root, name, "this is not lua")

    assert %{status: {:error, _}} = Runner.info(name)
    assert {:error, {:not_running, {:error, _}}} = Runner.call(name, "anything", [])
  end

  test "an action that errors leaves the pickle running with its state", %{
    root: root,
    name: name
  } do
    lua = """
    count = 7
    function get() return count end
    function boom() error("no") end
    """

    install_and_start(root, name, lua)

    assert {:error, _} = Runner.call(name, "boom", [])
    assert {:ok, [7]} = Runner.call(name, "get", [])
  end

  test "calling a function the script did not define says so", %{root: root, name: name} do
    install_and_start(root, name, "x = 1")
    assert {:error, :no_such_function} = Runner.call(name, "nothing", [])
  end

  test "timers tick and keep the state they build", %{root: root, name: name} do
    lua = """
    ticks = 0

    function on_start()
      mayo.timer.every(1, "tick")
    end

    function tick()
      ticks = ticks + 1
    end

    function get() return ticks end
    """

    install_and_start(root, name, lua, %{"capabilities" => ["timers"]})

    # The 1 ms interval is clamped to the 250 ms floor, so within a second
    # there have been a few ticks -- the exact count is the scheduler's
    # business, at least one is ours.
    Process.sleep(800)
    assert {:ok, [ticks]} = Runner.call(name, "get", [])
    assert ticks >= 1
  end

  test "calls that are not running answer :not_running, not an exit" do
    assert {:error, :not_running} = Runner.call("never-installed", "x", [])
    assert {:error, :not_running} = Runner.info("never-installed")
  end
end
