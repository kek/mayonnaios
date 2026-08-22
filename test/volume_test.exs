defmodule MayonnaiOS.VolumeTest do
  # Not async: the fake mixer reports through a registered name, so that the
  # same recording works whether the call came from this process or from
  # inside the Volume process.
  use ExUnit.Case, async: false

  alias MayonnaiOS.{Audio, Volume}

  # There is no ALSA on the machine these tests run on, so the mixer is a
  # module that records what it was asked to do. That is the whole seam:
  # everything that can be wrong about volume without the hardware saying so
  # -- the ladder, the clamping, whether any level closes the route to the
  # sink, which control gets named -- is arithmetic and argument lists, and
  # both are readable from here.
  #
  # That middle one is the reason this file grew: the argument list `["0%",
  # "mute"]` and the argument list `["0%", "unmute"]` are the difference
  # between a quiet handheld and one where every game freezes, and a test that
  # only counted percentages could not tell them apart.
  defmodule FakeMixer do
    @behaviour MayonnaiOS.Audio.Mixer

    @recorder MayonnaiOS.VolumeTest.Recorder

    @impl MayonnaiOS.Audio.Mixer
    def set(control, args) do
      if pid = Process.whereis(@recorder), do: send(pid, {:mixer, control, args})
      :ok
    end
  end

  # A mixer with no `amixer` behind it, for the failure path.
  defmodule BrokenMixer do
    @behaviour MayonnaiOS.Audio.Mixer

    @impl MayonnaiOS.Audio.Mixer
    def set(_control, _args), do: {:error, {:no_tool, "amixer"}}
  end

  setup do
    Process.register(self(), MayonnaiOS.VolumeTest.Recorder)
    :ok
  end

  defp writes, do: Enum.reverse(drain([]))

  defp drain(acc) do
    receive do
      {:mixer, control, args} -> drain([{control, args} | acc])
    after
      0 -> acc
    end
  end

  describe "Audio.clamp/1" do
    test "saturates rather than wrapping at either end" do
      # Wrapping would put the device at full volume one press past silence,
      # in a pocket, which is the one outcome worth designing against.
      assert Audio.clamp(-1) == 0
      assert Audio.clamp(-99) == 0
      assert Audio.clamp(Audio.steps() + 1) == Audio.steps()
      assert Audio.clamp(999) == Audio.steps()
    end

    test "leaves everything in range alone" do
      for level <- 0..Audio.steps(), do: assert(Audio.clamp(level) == level)
    end
  end

  describe "Audio.percent/1" do
    test "level 0 is 0% and the top level is 100%" do
      assert Audio.percent(0) == 0
      assert Audio.percent(Audio.steps()) == 100
    end

    test "the first audible level is not near-silence" do
      # The point of a floor: the control's range is 73 dB, so the bottom of
      # it is inaudible rather than quiet. A rocker whose first presses do
      # nothing you can hear is indistinguishable from one that is not wired
      # up, which is the bug this module exists to fix.
      assert Audio.percent(1) == Audio.quietest()
      assert Audio.percent(1) >= 25
    end

    test "rises with every step, and never stalls" do
      # A stalled step is a press that changes nothing. Rounding a ladder onto
      # a percentage is exactly where that would come from.
      percents = Enum.map(1..Audio.steps(), &Audio.percent/1)
      assert percents == Enum.sort(percents)
      assert length(Enum.uniq(percents)) == length(percents)
    end

    test "is clamped, so an out-of-range level is still a percentage" do
      assert Audio.percent(-5) == 0
      assert Audio.percent(Audio.steps() + 5) == 100
    end

    test "no two levels land on the same raw value of the DAC control" do
      # The step that matters is the one the *hardware* takes, and a ladder in
      # percent only survives contact with a 0-63 control if it does not round
      # two levels onto the same number. That would be a press that changes
      # nothing, which is the failure this whole module is about.
      #
      # The conversion is amixer's own, read out of alsa-utils 1.2.15.2 --
      # the version Buildroot builds for this image -- rather than remembered:
      #
      #     static long convert_prange1(long perc, long min, long max)
      #     {
      #             tmp = rint((double)perc * (double)(max - min) * 0.01);
      #             if (tmp == 0 && perc > 0) tmp++;
      #             return tmp + min;
      #     }
      #
      # It is linear in the *raw* value, and stays that way because nothing
      # here passes `-M`, which is the only thing that would switch amixer to
      # its mapped scale (`std_vol_type = VOL_RAW` otherwise). Whether an even
      # ladder in raw is also an even ladder in loudness depends on the
      # control's own dB scale, which is an assumption rather than a
      # measurement; see the moduledoc. Distinct raw values are the part that
      # can be asserted from here, and the part that matters most: two levels
      # rounding onto one raw value is a press that does nothing.
      dac_max = 63
      raws = Enum.map(1..Audio.steps(), &amixer_raw(Audio.percent(&1), 0, dac_max))

      assert length(Enum.uniq(raws)) == Audio.steps()
      assert raws == Enum.sort(raws)
      assert List.last(raws) == dac_max
    end
  end

  describe "Audio.set_level/2" do
    test "level 0 is 0% with the output path left switched on" do
      # The bug this replaces: level 0 used to switch DAC, Line Out and
      # Speaker off, and a closed route to the sink is not a quiet device, it
      # is one where ALSA never powers the DAC. Writes to the PCM then return
      # EIO, and a program that waits for buffer space instead -- RetroArch --
      # waits in poll() for ever. Measured on the device: `aplay /dev/zero`
      # fails with "Input/output error" in that state and succeeds in this
      # one.
      assert Audio.set_level(0, FakeMixer) == :ok

      assert writes() == [
               {"DAC", ["0%", "unmute"]},
               {"Line Out", ["100%", "unmute"]},
               {"Speaker", ["unmute"]}
             ]
    end

    test "no level, anywhere on the ladder, ever closes a switch" do
      # The invariant, stated once over the whole range rather than at the two
      # ends: silence is a gain here and nothing else. `mute` appearing in any
      # of these argument lists is the whole failure coming back.
      for level <- -3..(Audio.steps() + 3) do
        Audio.set_level(level, FakeMixer)

        for {control, args} <- writes() do
          refute "mute" in args, "level #{level} closed #{control}"
          assert "unmute" in args
        end
      end
    end

    test "every level writes the same three controls, differing only in the gain" do
      # Which is the shape of the fix: one clause, and the level decides a
      # percentage rather than a route.
      shapes =
        for level <- 0..Audio.steps() do
          Audio.set_level(level, FakeMixer)
          Enum.map(writes(), fn {control, args} -> {control, List.last(args)} end)
        end

      assert length(Enum.uniq(shapes)) == 1
    end

    test "an audible level sets the gain with the path already open" do
      assert Audio.set_level(1, FakeMixer) == :ok

      writes = writes()
      assert {"DAC", ["#{Audio.quietest()}%", "unmute"]} in writes
      assert {"Line Out", ["100%", "unmute"]} in writes
      assert {"Speaker", ["unmute"]} in writes
    end

    test "the amplifier is switched on last" do
      # Nothing here can hear the difference, but the ordering is why there is
      # no moment where a switched-on output carries a level nobody asked for.
      for level <- 0..Audio.steps() do
        Audio.set_level(level, FakeMixer)
        assert {"Speaker", ["unmute"]} = List.last(writes())
      end
    end

    test "volume lives on the DAC control, named and not indexed" do
      # Regulator indices on this board's PMIC are enumeration order rather
      # than identity, and the same reasoning applies to mixer controls: the
      # only thing that identifies this one is the string.
      Audio.set_level(5, FakeMixer)
      assert Enum.any?(writes(), &match?({"DAC", [_, "unmute"]}, &1))
    end

    test "Line Out is held at the setting the test tone was heard at" do
      for level <- 1..Audio.steps() do
        Audio.set_level(level, FakeMixer)
        assert {"Line Out", ["100%", "unmute"]} in writes()
      end
    end

    test "the Speaker switch is never given a percentage" do
      # amixer errors on `0%` for a control that is only a switch, and that
      # error would abort the rest of the ladder.
      for level <- 0..Audio.steps() do
        Audio.set_level(level, FakeMixer)

        for {control, args} <- writes(), control == "Speaker" do
          refute Enum.any?(args, &String.ends_with?(&1, "%"))
        end
      end
    end

    test "out-of-range levels are clamped rather than refused" do
      Audio.set_level(99, FakeMixer)
      assert {"DAC", ["100%", "unmute"]} in writes()

      Audio.set_level(-99, FakeMixer)
      assert {"DAC", ["0%", "unmute"]} in writes()
    end

    test "stops at the first control that will not set" do
      assert Audio.set_level(3, BrokenMixer) == {:error, {:no_tool, "amixer"}}
    end
  end

  describe "Audio.silence/1 and Audio.full/1" do
    test "silence is level 0 and full is the top of the ladder" do
      Audio.silence(FakeMixer)
      quiet = writes()
      Audio.set_level(0, FakeMixer)
      assert writes() == quiet

      Audio.full(FakeMixer)
      loud = writes()
      Audio.set_level(Audio.steps(), FakeMixer)
      assert writes() == loud
    end

    test "full is the state the test tone was heard in" do
      Audio.full(FakeMixer)
      writes = writes()
      assert {"DAC", ["100%", "unmute"]} in writes
      assert {"Line Out", ["100%", "unmute"]} in writes
      assert {"Speaker", ["unmute"]} in writes
    end

    test "silence leaves a device that can still play" do
      # The one sentence this whole change is about: after the boot step, the
      # three switches that make up the route to the sink are on. On the
      # hardware that is the difference between `aplay /dev/zero` returning
      # EIO and returning 0.
      Audio.silence(FakeMixer)

      assert Enum.sort(writes()) ==
               Enum.sort([
                 {"DAC", ["0%", "unmute"]},
                 {"Line Out", ["100%", "unmute"]},
                 {"Speaker", ["unmute"]}
               ])
    end
  end

  describe "Audio.disable_output/1" do
    test "closes all three switches, which is the state nothing can play in" do
      # Kept as an explicit act and named for what it does. It is not a volume
      # level, nothing in the firmware calls it, and the rocker cannot reach
      # it -- but `amixer sset Speaker mute` is one line anybody can type, so
      # the consequence is written down next to a function rather than nowhere.
      assert Audio.disable_output(FakeMixer) == :ok

      assert writes() == [
               {"Speaker", ["mute"]},
               {"DAC", ["0%", "mute"]},
               {"Line Out", ["0%", "mute"]}
             ]
    end

    test "the amplifier goes off first" do
      Audio.disable_output(FakeMixer)
      assert [{"Speaker", ["mute"]} | _] = writes()
    end

    test "any level undoes it, silence included" do
      Audio.disable_output(FakeMixer)
      _ = writes()

      Audio.set_level(0, FakeMixer)

      for {_control, args} <- writes(), do: assert("unmute" in args)
    end
  end

  describe "the boot state" do
    # The state a freshly powered device is in is the one state every audio
    # program has to cope with, and until now it was only assertable by
    # booting a device and listening. `Startup.run/1` takes the mixer for
    # exactly that reason.

    test "is 0% with the output path open, not 0% with it closed" do
      assert Audio.Startup.run(FakeMixer) == :ok

      assert writes() == [
               {"DAC", ["0%", "unmute"]},
               {"Line Out", ["100%", "unmute"]},
               {"Speaker", ["unmute"]}
             ]
    end

    test "is not disable_output/1" do
      # These were the same call, and that was the bug.
      Audio.Startup.run(FakeMixer)
      booted = writes()

      Audio.disable_output(FakeMixer)
      refute writes() == booted
    end

    test "closes nothing, so a program that opens ALSA after boot can play" do
      Audio.Startup.run(FakeMixer)

      for {control, args} <- writes() do
        refute "mute" in args, "boot closed #{control}"
      end
    end

    test "a mixer that cannot be reached is a warning and not a crash" do
      # It must not take the boot down. What it leaves behind is worse than it
      # used to be -- the hardware's own closed path -- which is why the
      # warning says so, and why this returns rather than raising.
      assert Audio.Startup.run(BrokenMixer) == :ok
    end
  end

  describe "the device it opens" do
    test "is looked up by name, and its absence is a line naming the name" do
      # The rocker was `/dev/input/event1` in this file until the numbering
      # moved, and by then `event1` was the analog stick -- a device with no
      # keys on it at all. A fallback to that number is not a degraded volume
      # control, it is a process waiting for ever for `KEY_VOLUMEUP` from
      # something that has never sent one, and the only visible symptom is
      # that the buttons do nothing.
      #
      # So there is no number to fall back to, and what makes that better
      # rather than merely stricter is this log line: it names the device tree
      # name, which is the thing that would have to change for this to happen.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_supervised!({Volume, mixer: FakeMixer})
        end)

      assert log =~ "gpio-keys-volume"
      refute log =~ "/dev/input/event"
    end
  end

  describe "the rocker" do
    setup do
      # No device: there is no /dev/input here, so Volume degrades to "no
      # rocker" and takes its events from send/2 instead. The shape is the one
      # the InputEvent driver delivers, so what is exercised below is the code
      # the device runs.
      pid = start_supervised!({Volume, [device: "/dev/input/nothing", mixer: FakeMixer]})
      %{volume: pid}
    end

    test "starts silent, because that is what boot leaves the mixer at", %{volume: pid} do
      assert Volume.level(pid) == 0
    end

    test "writes nothing at startup", %{volume: pid} do
      # The boot state is already silence. A process that re-asserted it would
      # be a second thing deciding how loud a freshly booted device is.
      assert Volume.level(pid) == 0
      assert writes() == []
    end

    test "volume up from silence goes to level 1 with the path still open", %{volume: pid} do
      press(pid, :key_volumeup)
      assert Volume.level(pid) == 1
      assert {"Speaker", ["unmute"]} in writes()
    end

    test "each press moves exactly one level", %{volume: pid} do
      for expected <- 1..Audio.steps() do
        press(pid, :key_volumeup)
        assert Volume.level(pid) == expected
      end
    end

    test "presses past the top stay at the top", %{volume: pid} do
      for _ <- 1..(Audio.steps() + 5), do: press(pid, :key_volumeup)
      assert Volume.level(pid) == Audio.steps()
    end

    test "presses past silence stay at silence", %{volume: pid} do
      for _ <- 1..5, do: press(pid, :key_volumedown)
      assert Volume.level(pid) == 0
    end

    test "down from level 1 is silence, and does not close the path", %{volume: pid} do
      # The rocker walking back to the bottom of its travel must not be able
      # to take audio away from a program that is playing. It could, and the
      # device was found with a game frozen in poll() because of it.
      press(pid, :key_volumeup)
      _ = writes()
      press(pid, :key_volumedown)

      assert Volume.level(pid) == 0
      writes = writes()
      assert {"DAC", ["0%", "unmute"]} in writes
      assert {"Speaker", ["unmute"]} in writes
      refute Enum.any?(writes, fn {_control, args} -> "mute" in args end)
    end

    test "no sequence of presses can ever close the path", %{volume: pid} do
      # Whatever someone does with the two keys -- squeezing both, running the
      # ladder to either end and back -- the route to the sink stays open.
      for key <- [:key_volumedown, :key_volumeup, :key_volumedown, :key_volumeup],
          _ <- 1..(Audio.steps() + 2) do
        press(pid, key)

        for {control, args} <- writes() do
          refute "mute" in args, "#{key} closed #{control}"
        end
      end
    end

    test "a press at the end of the travel still re-asserts the mixer", %{volume: pid} do
      # Deliberate: one press repairs a mixer that something else has moved --
      # `Audio.disable_output/0` from IEx, say -- rather than leaving the two
      # disagreeing until a reboot.
      _ = writes()
      press(pid, :key_volumedown)
      assert Volume.level(pid) == 0
      refute writes() == []
    end

    test "releases do nothing", %{volume: pid} do
      send(pid, {:input_event, "test", [{:ev_key, :key_volumeup, 0}]})
      assert Volume.level(pid) == 0
      assert writes() == []
    end

    test "autorepeat does nothing", %{volume: pid} do
      # Deliberate: holding the rocker does not ramp. If this ever changes it
      # should change because someone saw a repeat arrive from this device.
      send(pid, {:input_event, "test", [{:ev_key, :key_volumeup, 2}]})
      assert Volume.level(pid) == 0
      assert writes() == []
    end

    test "a report with both keys is a no-op, not two fighting writes", %{volume: pid} do
      press(pid, :key_volumeup)
      _ = writes()

      send(
        pid,
        {:input_event, "test", [{:ev_key, :key_volumeup, 1}, {:ev_key, :key_volumedown, 1}]}
      )

      assert Volume.level(pid) == 1
      assert writes() == []
    end

    test "gamepad keys on the same device are ignored", %{volume: pid} do
      send(pid, {:input_event, "test", [{:ev_key, :btn_b, 1}, {:ev_key, :btn_mode, 1}]})
      assert Volume.level(pid) == 0
      assert writes() == []
    end

    test "up/0 and down/0 move the same level the buttons do", %{volume: pid} do
      assert Volume.up(pid) == 1
      assert Volume.up(pid) == 2
      assert Volume.down(pid) == 1
    end

    test "set/1 clamps", %{volume: pid} do
      assert Volume.set(pid, 99) == Audio.steps()
      assert Volume.set(pid, -99) == 0
    end

    test "a mixer that cannot be reached still moves the level" do
      # So that a card which has gone away does not leave the rocker stuck on
      # the level it failed at, with every later press retrying the same one.
      stop_supervised!(Volume)
      pid = start_supervised!({Volume, [device: "/dev/input/nothing", mixer: BrokenMixer]})
      assert Volume.up(pid) == 1
      assert Volume.up(pid) == 2
    end
  end

  # amixer's percent-to-raw conversion, transcribed from `convert_prange1` in
  # alsa-utils 1.2.15.2. `rint` rounds half to even and `round/1` rounds half
  # away from zero; the only level that lands on an exact half here is 50% of
  # 0-63, and both give 32.
  defp amixer_raw(percent, min, max) do
    case round(percent * (max - min) * 0.01) do
      0 when percent > 0 -> 1 + min
      raw -> raw + min
    end
  end

  # The shape the InputEvent driver delivers, which is what the device sends.
  # The call afterwards is the synchronisation: it returns only once the send
  # above has been handled.
  defp press(pid, key) do
    send(pid, {:input_event, "test", [{:ev_key, key, 1}]})
    Volume.level(pid)
  end
end
