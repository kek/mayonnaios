defmodule MayonnaiOS.SleepTest do
  use ExUnit.Case, async: false

  alias MayonnaiOS.{Launcher, Sleep}

  # The backlight is a file, which is the whole reason this is testable on a
  # laptop: `Sleep` writes "0" or "1" to one sysfs attribute, so pointing
  # :backlight_brightness at a temp file exercises the same code path the
  # device runs. What no test can check is whether the panel goes dark -- that
  # is a GPIO on the other side of the write, and only eyes on the device
  # answer it.

  setup do
    path = Path.join(System.tmp_dir!(), "backlight-#{System.unique_integer([:positive])}")
    File.write!(path, "1")
    Application.put_env(:mayonnaios, :backlight_brightness, path)

    on_exit(fn ->
      Application.delete_env(:mayonnaios, :backlight_brightness)
      File.rm(path)
    end)

    %{path: path}
  end

  describe "the backlight write" do
    test "turns it off and on again", %{path: path} do
      assert Sleep.sleep() == :ok
      assert File.read!(path) == "0"
      assert Sleep.asleep?()

      assert Sleep.wake() == :ok
      assert File.read!(path) == "1"
      refute Sleep.asleep?()
    end

    test "is idempotent in both directions", %{path: path} do
      assert Sleep.sleep() == :ok
      assert Sleep.sleep() == :ok
      assert File.read!(path) == "0"
      assert Sleep.asleep?()

      assert Sleep.wake() == :ok
      assert Sleep.wake() == :ok
      assert File.read!(path) == "1"
      refute Sleep.asleep?()
    end

    test "reports a path that is not there rather than claiming success" do
      # The failure this project keeps producing is an inherited assumption
      # reported as success. A sysfs node that is absent, read-only, or
      # EACCES has to come back as an error, because the caller decides
      # whether to swallow button presses on the strength of the answer.
      Application.put_env(:mayonnaios, :backlight_brightness, "/nonexistent/dir/brightness")

      assert Sleep.sleep() == {:error, :enoent}
      assert Sleep.wake() == {:error, :enoent}
    end

    test "an unreadable brightness file reads as awake, not asleep" do
      # "We cannot tell" must not become "the screen is off": that reading is
      # the one that makes a caller eat the presses of someone staring at a
      # lit panel.
      Application.put_env(:mayonnaios, :backlight_brightness, "/nonexistent/dir/brightness")
      refute Sleep.asleep?()
    end

    test "trailing whitespace from sysfs still reads as asleep", %{path: path} do
      # Reading back a sysfs attribute normally yields a trailing newline.
      File.write!(path, "0\n")
      assert Sleep.asleep?()
    end
  end

  describe "the binding" do
    test "is the power key, on its own" do
      assert Sleep.binding() == {nil, :key_power}
      assert Sleep.trigger?(MapSet.new(), :key_power)
    end

    test "fires whatever else is held" do
      # A nil modifier means the held set is not consulted at all. That is the
      # property the launcher leans on when it asks this from the app path,
      # where what is held is somebody else's business.
      assert Sleep.trigger?(MapSet.new([:btn_select, :btn_start, :btn_mode]), :key_power)
    end

    test "the chord it replaced does nothing at all" do
      # This is the test that fails if Select+Start is kept "just in case".
      # It is not a spare tyre: it is a second trigger to write down in the
      # moduledoc, the launcher, the README, the keyboard bridge and the
      # supervision tree, and `@binding` is one tuple so that there is one
      # place to read it off. The full argument is in MayonnaiOS.Sleep.
      refute Sleep.trigger?(MapSet.new([:btn_select]), :btn_start)
      refute Sleep.trigger?(MapSet.new([:btn_select, :btn_start]), :btn_start)
    end

    test "no button on the pad sleeps the device" do
      pad = [:btn_a, :btn_b, :btn_x, :btn_y, :btn_select, :btn_start, :btn_mode]

      for key <- pad, held <- [MapSet.new(), MapSet.new(pad)] do
        refute Sleep.trigger?(held, key)
      end
    end
  end

  describe "the device the key arrives on" do
    test "is nil here, and never a number" do
      # The fallback used to be `/dev/input/event0`, which is the power key's
      # number on this firmware and was the gamepad's on the one before. Both
      # of those are accidents; the name is the thing that is meant.
      assert Sleep.device() == nil
    end

    # What no test here can check is that the *name* is right. Point
    # `@binding` at "gpio-keys-gamepad" and this suite stays green: on a
    # laptop both names resolve to nil, and the synthetic reports below carry
    # a device string the Launcher deliberately ignores. The name is checkable
    # against one thing only, which is the hardware --
    # `MayonnaiOS.Input.names/0` over SSH -- and this note is here so that
    # nobody reads a green run as having confirmed it.
  end

  describe "the launcher binding" do
    setup do
      programs = [%{path: "/a"}, %{path: "/b"}, %{path: "/c"}]
      Application.put_env(:mayonnaios, :programs, programs)
      on_exit(fn -> Application.delete_env(:mayonnaios, :programs) end)

      # No /dev/input here, so the synthetic reports below stand in for the
      # pad -- the same route MayonnaiOS.Keyboard uses on a laptop.
      start_supervised!({Launcher, device: "/nonexistent/event0"})
      :ok
    end

    test "the power key sleeps, and the next press only wakes", %{path: path} do
      press(:key_power)

      assert Launcher.asleep?()
      assert File.read!(path) == "0"

      # The press that wakes must not also do what it usually does: A here
      # would otherwise launch, and the cursor keys would move the menu.
      press(:btn_dpad_down)

      refute Launcher.asleep?()
      assert File.read!(path) == "1"
      assert Launcher.selected() == 0

      # And the one after it is an ordinary press again.
      press(:btn_dpad_down)
      assert Launcher.selected() == 1
    end

    test "releasing the key does not wake it", %{path: path} do
      press(:key_power)
      assert Launcher.asleep?()

      # The key is still down when the panel goes dark; its release arrives a
      # moment later and must not turn the panel straight back on.
      release(:key_power)

      assert Launcher.asleep?()
      assert File.read!(path) == "0"
    end

    test "the power key wakes it too, and does not put it straight back" do
      press(:key_power)
      assert Launcher.asleep?()

      # The one press that has to be idempotent in the other direction: the
      # button someone reaches for to bring the screen back is the same button
      # that darkened it, so waking must consume the press before the binding
      # gets a look at it.
      press(:key_power)
      refute Launcher.asleep?()

      # And it is an ordinary press again afterwards.
      press(:key_power)
      assert Launcher.asleep?()
    end

    # There is no longer a test that the held set is cleared on waking.
    #
    # It was worth having and its last observable consequence went away with
    # the chord: the held set now feeds exactly one thing, the Select+Menu
    # power-off, and a test that presses that chord calls
    # `Nerves.Runtime.poweroff/0`, which on the host begins stopping the VM
    # and takes the whole run down with no summary. `wake_up/1` still clears
    # it, for that chord's sake; see the comment there.

    test "a backlight that cannot be written does not swallow anything" do
      Application.put_env(:mayonnaios, :backlight_brightness, "/nonexistent/dir/brightness")

      press(:key_power)

      # The write failed, so the device is not asleep -- and the next press
      # does its ordinary job instead of being eaten by a sleep that never
      # happened.
      refute Launcher.asleep?()
      press(:btn_dpad_down)
      assert Launcher.selected() == 1
    end

    test "sleep from a console returns the write failure" do
      Application.put_env(:mayonnaios, :backlight_brightness, "/nonexistent/dir/brightness")

      assert Launcher.sleep() == {:error, :enoent}
      refute Launcher.asleep?()
    end

    test "sleep and wake from a console are idempotent", %{path: path} do
      assert Launcher.sleep() == :ok
      assert Launcher.sleep() == :ok
      assert Launcher.asleep?()
      assert File.read!(path) == "0"

      assert Launcher.wake() == :ok
      assert Launcher.wake() == :ok
      refute Launcher.asleep?()
      assert File.read!(path) == "1"
    end
  end

  # A stand-in for an app that runs in this VM, recording what it was handed.
  # Small on purpose: the only thing under test here is which reports reach it.
  defmodule FakeApp do
    def start(_opts \\ []) do
      Agent.update(__MODULE__, &%{&1 | started: &1.started + 1})
      {:ok, self()}
    end

    def stop, do: :ok

    def input(events) do
      Agent.update(__MODULE__, &%{&1 | events: &1.events ++ [events]})
      :ok
    end

    def scene, do: MayonnaiOS.Scene.Home

    def log, do: Agent.get(__MODULE__, & &1)
  end

  describe "the power key while an app has the buttons" do
    # An app running in this VM is handed every report the launcher gets, so
    # that whatever has the screen has the input. The sleep key is the one
    # exception, and this is the pair of tests that says so: the panel goes
    # dark, and the app is not told about a key it has no use for.
    setup do
      start_supervised!(%{
        id: FakeApp,
        start: {Agent, :start_link, [fn -> %{started: 0, events: []} end, [name: FakeApp]]}
      })

      Application.put_env(:mayonnaios, :programs, [%{name: "Fake", app: FakeApp}])
      on_exit(fn -> Application.delete_env(:mayonnaios, :programs) end)

      start_supervised!({Launcher, device: "/nonexistent/event0"})

      # A starts it. :btn_b is the button silkscreened A; see the Launcher.
      press(:btn_b)
      assert FakeApp.log().started == 1
      :ok
    end

    test "still sleeps the panel", %{path: path} do
      press(:key_power)

      assert Launcher.asleep?()
      assert File.read!(path) == "0"
    end

    test "is not forwarded to the app, and the pad still is" do
      # The pad's buttons are the app's and go across untouched.
      press(:btn_dpad_down)
      assert FakeApp.log().events == [[{:ev_key, :btn_dpad_down, 1}]]

      # The power key is not on the pad, and the app would only drop it. Note
      # the order: after this the panel is dark, and the next press of anything
      # is spent on waking and does not reach the app either.
      press(:key_power)
      assert FakeApp.log().events == [[{:ev_key, :btn_dpad_down, 1}]]
    end
  end

  defp press(key), do: send_events([{:ev_key, key, 1}])
  defp release(key), do: send_events([{:ev_key, key, 0}])

  defp send_events(events) do
    send(Launcher, {:input_event, "/nonexistent/event0", events})
    # A call is ordered behind the messages above, so this is the sync point.
    Launcher.asleep?()
  end
end
