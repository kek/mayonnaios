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

  describe "the chord" do
    test "is Select plus a key the launcher does not otherwise bind" do
      assert Sleep.binding() == {:btn_select, :btn_start}
      assert Sleep.trigger?(MapSet.new([:btn_select, :btn_start]), :btn_start)
    end

    test "does not fire on the key alone" do
      # The point of the modifier: this is a handheld in a pocket, and a bare
      # Start must not blank the screen.
      refute Sleep.trigger?(MapSet.new([:btn_start]), :btn_start)
    end

    test "does not fire on the modifier alone, or on the power-off chord" do
      refute Sleep.trigger?(MapSet.new([:btn_select]), :btn_select)
      refute Sleep.trigger?(MapSet.new([:btn_select, :btn_mode]), :btn_mode)
    end
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

    test "Select+Start sleeps, and the next press only wakes", %{path: path} do
      # A press with no release is a hold, which is all the launcher's held
      # set records -- so this is Select held down and Start pressed.
      press(:btn_select)
      press(:btn_start)

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

    test "releasing the chord does not wake it", %{path: path} do
      press(:btn_select)
      press(:btn_start)
      assert Launcher.asleep?()

      # Both keys are still down when the device goes to sleep; their
      # releases arrive a moment later and must not turn the panel straight
      # back on.
      release(:btn_start)
      release(:btn_select)

      assert Launcher.asleep?()
      assert File.read!(path) == "0"
    end

    test "the press that wakes cannot be half of a chord" do
      press(:btn_select)
      press(:btn_start)
      assert Launcher.asleep?()

      # Select is still down as far as the kernel is concerned. Waking on it
      # consumes the press, and the held set goes with it -- otherwise the
      # very next Start would put the device back to sleep, and the very next
      # Menu would power it off, from presses nobody meant as chords.
      press(:btn_select)
      refute Launcher.asleep?()

      press(:btn_start)
      refute Launcher.asleep?()
    end

    test "a backlight that cannot be written does not swallow anything" do
      Application.put_env(:mayonnaios, :backlight_brightness, "/nonexistent/dir/brightness")

      press(:btn_select)
      press(:btn_start)

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

  defp press(key), do: send_events([{:ev_key, key, 1}])
  defp release(key), do: send_events([{:ev_key, key, 0}])

  defp send_events(events) do
    send(Launcher, {:input_event, "/nonexistent/event0", events})
    # A call is ordered behind the messages above, so this is the sync point.
    Launcher.asleep?()
  end
end
