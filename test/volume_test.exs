defmodule MayonnaiOS.VolumeTest do
  # Not async: the fake mixer reports through a registered name, so that the
  # same recording works whether the call came from this process or from
  # inside the Volume process.
  use ExUnit.Case, async: false

  alias MayonnaiOS.{Audio, Volume}

  # There is no ALSA on the machine these tests run on, so the mixer is a
  # module that records what it was asked to do. That is the whole seam:
  # everything that can be wrong about volume without the hardware saying so
  # -- the ladder, the clamping, whether raising from silence also unswitches
  # the outputs, which control gets named -- is arithmetic and argument lists,
  # and both are readable from here.
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
    test "level 0 mutes every playback control and drops it to 0%" do
      assert Audio.set_level(0, FakeMixer) == :ok

      assert writes() == [
               {"Speaker", ["mute"]},
               {"DAC", ["0%", "mute"]},
               {"Line Out", ["0%", "mute"]}
             ]
    end

    test "an audible level unmutes as well as setting the gain" do
      # The mute interaction is the failure mode being fixed: this device
      # boots muted, so a volume-up that only moved a percentage would move a
      # number behind a closed switch and make no sound at all.
      assert Audio.set_level(1, FakeMixer) == :ok

      writes = writes()
      assert {"DAC", ["#{Audio.quietest()}%", "unmute"]} in writes
      assert {"Line Out", ["100%", "unmute"]} in writes
      assert {"Speaker", ["unmute"]} in writes
    end

    test "the amplifier is switched on last and off first" do
      # Nothing here can hear the difference, but the ordering is why there is
      # no moment where a switched-on output carries a level nobody asked for.
      Audio.set_level(Audio.steps(), FakeMixer)
      assert {"Speaker", ["unmute"]} = List.last(writes())

      Audio.set_level(0, FakeMixer)
      assert [{"Speaker", ["mute"]} | _] = writes()
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
      assert {"DAC", ["0%", "mute"]} in writes()
    end

    test "stops at the first control that will not set" do
      assert Audio.set_level(3, BrokenMixer) == {:error, {:no_tool, "amixer"}}
    end
  end

  describe "Audio.mute/1 and Audio.unmute/1" do
    test "mute is level 0 and unmute is the top of the ladder" do
      Audio.mute(FakeMixer)
      muted = writes()
      Audio.set_level(0, FakeMixer)
      assert writes() == muted

      Audio.unmute(FakeMixer)
      loud = writes()
      Audio.set_level(Audio.steps(), FakeMixer)
      assert writes() == loud
    end

    test "unmute is the state the test tone was heard in" do
      Audio.unmute(FakeMixer)
      writes = writes()
      assert {"DAC", ["100%", "unmute"]} in writes
      assert {"Line Out", ["100%", "unmute"]} in writes
      assert {"Speaker", ["unmute"]} in writes
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

    test "volume up from silence goes to level 1, unmuting on the way", %{volume: pid} do
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

    test "down from level 1 is silence, and mutes", %{volume: pid} do
      press(pid, :key_volumeup)
      _ = writes()
      press(pid, :key_volumedown)
      assert Volume.level(pid) == 0
      assert {"Speaker", ["mute"]} in writes()
    end

    test "a press at the end of the travel still re-asserts the mixer", %{volume: pid} do
      # Deliberate: one press repairs a mixer that something else has moved --
      # `Audio.unmute/0` from IEx, say -- rather than leaving the two
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
