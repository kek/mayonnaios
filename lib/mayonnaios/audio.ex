defmodule MayonnaiOS.Audio do
  @moduledoc """
  The mixer: the levels the volume rocker moves, and the test tone that
  settled whether audio works at all.

  **Audio works.** Confirmed on hardware: unmute the mixer, play 440 Hz, and
  the speaker produces it. So the codec routing inherited from
  `rg35xx-plus.dts` does describe this board after all, and the last large
  question about that inheritance is closed.

  Getting there needed the two steps in the right order, and the order was
  the whole point:

    * the codec was bound -- `aplay -l` lists *card 0: Codec [H616 Audio
      Codec]* -- so the "no card" failure was ruled out by reading alone
    * the mixer was **muted** -- `DAC` at 100% with its switch off, `Line Out`
      at 0% and off

  Playing first would have produced silence, and silence would have been read
  as evidence that the inherited device tree was wrong. It would have been
  evidence about a default. Unmute, *then* play, or the result means nothing.

  ## The device boots silent, and *how* it does that is the whole story

  `Startup` puts the volume at the bottom of the ladder and leaves the output
  path **switched on**. Silence at boot is a gain, not a route.

  Booting quiet is still the right intent, and it is the same intent as
  before: there is no `/var/lib/alsa/asound.state` and nothing runs `alsactl
  restore`, so the mixer powers on with `DAC` off and `Line Out` at 0%
  anyway. Setting it explicitly rather than inheriting it is the point -- a
  default that happens to be right is the exact shape of thing this board has
  already been wrong about twice, and a handheld that makes a noise nobody
  asked for, in a pocket, is a worse failure than one that starts quiet.

  What was wrong was the mechanism. `Startup` used to switch every playback
  control *off*, which is silent and is also a device on which no program can
  play anything at all. Two `aplay` runs on the hardware, three weeks apart
  in understanding and two seconds apart on the wire, both writing
  `/dev/zero` so that every sample is zero and the test is silent by content
  rather than by volume:

      # DAC, Line Out and Speaker all switched off -- the old boot state
      aplay -D hw:0,0 -f S32_LE -r 48000 -c 2 -d 2 /dev/zero
      aplay: pcm_write:2191: write error: Input/output error     (exit 1)

      # DAC 0% but on, Line Out on, Speaker on -- the new boot state
      aplay -D hw:0,0 -f S32_LE -r 48000 -c 2 -d 2 /dev/zero     (exit 0)

  ALSA's DAPM only powers a path that has a complete route to an *enabled
  sink*. Switches off is no sink, so the DAC never powers up and a write to
  the PCM returns `EIO`. Turning on `DAC` and `Line Out` but leaving
  `Speaker` off was still not enough: the sink is the part that matters,
  which is why the amplifier is in the ladder at all.

  ## What the closed path actually cost

  Games hung. Not the display and not the RetroArch build -- both were ruled
  out separately, and with `audio_enable = false` the emulator ran at a clean
  60 fps of page flips. What happened instead is that RetroArch filled its
  3072-frame ALSA buffer, blocked in `poll()` waiting for space that a
  powered-down DAC would never make, and never returned to its main loop. A
  hung one showed `state: RUNNING`, `hw_ptr` frozen at 48 frames -- one
  millisecond of audio -- `appl_ptr: 3091`, `avail: 29`. With the path open
  and the volume at 0 the same game runs and `hw_ptr` advances 48048 frames a
  second.

  Nothing about that looks like audio from the outside, which is why it took
  so long: a frozen game on a frozen screen. And it had been hiding in plain
  sight, because whoever was testing had usually played a test tone first,
  and the tone opens the path. Pressing volume up once before launching is
  the same accident, and it was the workaround nobody knew they were using --
  the ladder opens the switches on the way up from silence.

  Worth knowing because it is the same failure with the launcher innocent:
  the device was found with a *running* game frozen because the rocker had
  been walked back down to 0, and level 0 closed the path underneath it. The
  ring buffer's own log has `[volume] level 0/10 (0%)` and the PCM's `hw_ptr`
  stopping in the same second. Silence that cannot be undone by the program
  making it is not a volume setting, it is a fault.

  ## One silence, and one thing that is not silence

  So there is exactly one notion of quiet here and the rocker owns it: level
  0, `DAC` at 0%, path open, `silence/1`. `disable_output/1` is the other
  thing -- it closes the switches, and it is documented as what it is, a
  device that cannot play rather than one that plays inaudibly. Nothing calls
  it. It is not the boot state and it is not reachable from the rocker.

  Raising the volume is still a deliberate act. `MayonnaiOS.Volume` makes the
  rocker on the shell that act; `full/1` is the same thing from IEx.

  ## The cost of leaving Speaker on at boot

  `Speaker` is an amplifier, and it is now on from boot with nothing playing.
  The plausible costs are idle hiss and idle current, and **neither has been
  measured** -- nobody has put an ear to a booted device listening for it, or
  compared battery drain with the switch either way. They are worth a
  measurement before anyone concludes this is free.

  What is not in doubt is the other side of the trade: with the switch off,
  every program that opens ALSA fails or hangs, silently, until a human
  presses a button. A hiss nobody has heard is a better bug than a device
  that freezes on the first game.

  ## Which control is the volume, and which are routing

  Five simple controls exist on this card. Read off the device with `amixer
  scontents`, not guessed:

      Speaker           pswitch only, mono          -- the amplifier
      Line Out          0-31, pswitch, -inf..0 dB   -- the analog output
      Line Out Source   enum: Stereo / Mono Diff.
      DAC               0-63, pswitch, -73.08..0 dB -- the digital gain
      DAC Reversed      pswitch

  `DAC` carries the volume and the other two are held at the setting that is
  already known to work. Three reasons, and they are all about not inventing
  an operating point nobody has heard:

    * `Line Out`'s bottom step reads `-99999.99dB`, which is a mute marker
      rather than an attenuation. A control whose first step is silence is a
      switch with extra numbers, not a volume ramp.
    * `DAC` has 63 steps and reads `-73.08dB` at the bottom of them, so it is
      the finer of the two and the one with a usable floor.
    * With `DAC` at full and `Line Out` at full, this is exactly the state the
      test tone was heard in. So the loudest setting here is the *verified*
      setting, and every other level is that state attenuated digitally.

  What is not established is the shape of the `DAC` scale between its ends.
  Two dB readings came off the hardware -- `-73.08` at raw 0, and 0 dB
  implied at the top -- and a linear scale between them would make 1.16 dB a
  step. That is the ordinary shape for this kind of control and it is what the
  even ladder below assumes, but nobody has read a midpoint: the device stopped
  answering filesystem calls before it could be asked. If the middle of the
  rocker's travel turns out to be bunched at one end, this is the assumption
  that was wrong.

  Matching on the name matters and is not decoration: this project has
  already been bitten by `regulator.3` and `regulator.4` swapping identity
  between two drivers of the same PMIC. `amixer sset DAC` names the control;
  nothing here indexes into a list.

  ## The levels

  `steps/0` levels plus silence, and level 0 is `silence/1` -- the boot state.
  Levels are mapped onto the control's percentage range starting at
  `quietest/0` rather than at 0%, because the bottom of a 73 dB range is not
  a quiet setting, it is an inaudible one. Ten presses that do nothing you
  can hear is indistinguishable from a rocker that is not wired up, which is
  the failure this exists to fix.

  Both numbers are single constants and both are judgement, not measurement:
  nobody has yet listened to level 1. If the quietest step is too loud, or
  the ladder too coarse, `@steps` and `@quietest` are the two things to move.
  The one thing that *is* checked is that no two levels round onto the same
  raw value of a 0-63 control, because a press that changes nothing is the
  failure this is here to fix; see `MayonnaiOS.VolumeTest`.

  ## The test tone

  `run/0` goes to full volume and plays one second of sine. It is not bound
  to a button.
  It was bound to Y while audio was the open question; that question is
  closed, and leaving a key on the pad that makes noise is not what the key
  is for. Call it from IEx when the mixer needs checking again:

      iex> MayonnaiOS.Audio.run()
  """

  require Logger

  alias MayonnaiOS.Audio.Amixer

  # How many audible levels the rocker walks through, above silence.
  @steps 10

  # Level 1, as a percentage of the DAC control's range. 50% of 0-63 is raw
  # 32, which on a scale of -73.08 dB to 0 dB in 1.16 dB steps is about
  # -36 dB below the level the test tone was heard at. Quiet, and not silent.
  @quietest 50

  @doc """
  The number of audible levels. Level 0 is silence, so the range is `0..steps`.
  """
  def steps, do: @steps

  @doc """
  Level 1 as a percentage of the volume control's range.
  """
  def quietest, do: @quietest

  @doc """
  Hold a level inside `0..steps/0`.

  The rocker at either end of its travel is not an error, it is a rocker at
  the end of its travel, so this saturates rather than wrapping. Wrapping
  would put a device at full volume one press past silence.
  """
  @spec clamp(integer()) :: non_neg_integer()
  def clamp(level) when is_integer(level), do: level |> max(0) |> min(@steps)

  @doc """
  The percentage the volume control is set to for `level`.

  0 for silence; `quietest/0` for level 1, rising to 100 at `steps/0`. The
  spacing is even in percent, which on this control is even in dB.
  """
  @spec percent(integer()) :: non_neg_integer()
  def percent(level) when is_integer(level) do
    case clamp(level) do
      0 -> 0
      n -> @quietest + round((100 - @quietest) * (n - 1) / (@steps - 1))
    end
  end

  @doc """
  Whether the audio test has been switched on. False unless configured.
  """
  def enabled?, do: Application.get_env(:mayonnaios, :audio_test, false)

  @doc """
  Go to full volume, then play a short test. Refuses unless `enabled?/0`.

  Not bound to any button -- call it from IEx. Returns `{:error, :disabled}`,
  `{:error, {:no_tool, name}}` or `:ok`.
  """
  def run do
    if enabled?() do
      with :ok <- full() do
        play()
      end
    else
      Logger.info("[audio] test is disabled; set config :mayonnaios, audio_test: true")
      {:error, :disabled}
    end
  end

  @doc """
  Put the mixer at `level`, between 0 and `steps/0`.

  Every level, level 0 included, leaves the output path switched on. The only
  thing a level decides is the `DAC` percentage; the route from the DAC to
  the speaker is the same at silence as it is at full, which is what makes
  the bottom of the ladder inaudible rather than impossible. See the
  moduledoc for what the other arrangement cost.

  The whole ladder is written on every call rather than only the control that
  moved. It costs two more `amixer` runs per press and it means one press
  restores a mixer that something else has changed underneath --
  `disable_output/1` from IEx, say -- instead of leaving the two disagreeing
  until a reboot. That is now load-bearing rather than tidy: one press of
  volume up is what re-opens a path something else closed.

  `mixer` is the seam the tests use; see `MayonnaiOS.Audio.Mixer`.
  """
  @spec set_level(integer(), module()) :: :ok | {:error, term()}
  def set_level(level, mixer \\ Amixer) when is_integer(level) do
    level |> clamp() |> controls_for() |> apply_controls(mixer)
  end

  @doc """
  The top of the ladder: full gain, path open.

  A deliberate act, not a boot step. Makes no sound by itself. This is the
  state the test tone was heard in, and it is the top of the volume ladder --
  the same thing said two ways, deliberately.

  Named `full/1` rather than `unmute/1`, which is what it used to be called.
  Nothing here is muted any more, at any level, so a function named for
  undoing a mute would be describing a state this module no longer produces.

  Note that `MayonnaiOS.Volume` does not learn about this: it holds the level
  it last set, so the next press moves from there rather than from full. One
  press puts the two back in agreement.
  """
  def full(mixer \\ Amixer), do: set_level(@steps, mixer)

  @doc """
  Level 0: the volume at its minimum, with the output path open.

  This is what `Startup` does at boot and what the rocker reaches at the
  bottom of its travel. `DAC` at 0% is -73.08 dB, which is inaudible rather
  than mathematically silent, and that is the trade being made on purpose:
  something that opens the PCM a moment later can write to it.

  Not what the hardware powers on as -- that is `disable_output/1`'s state,
  and setting this over it is the point of `Startup` existing.
  """
  def silence(mixer \\ Amixer), do: set_level(0, mixer)

  @doc """
  Switch the output path off: `DAC`, `Line Out` and `Speaker` all off.

  **This makes playback impossible, not merely inaudible.** ALSA's DAPM
  powers a path only when it has a complete route to an enabled sink, so with
  these three off the DAC never powers up: a write to the PCM returns `EIO`
  and a program that waits for buffer space instead -- RetroArch does -- waits
  in `poll()` for ever. That is a frozen game, and nothing about it looks like
  audio. The moduledoc has the measurements.

  So this is not "volume 0" and it is deliberately not on the ladder, not at
  boot, and not reachable from the rocker. It exists because "the amplifier
  is off" is a real hardware state someone may need on purpose -- listening
  for idle hiss, measuring idle current, proving the EIO above -- and because
  `amixer sset Speaker mute` is one line that anybody can type on the device
  whether or not this function exists. Better that the consequence is written
  down next to it.

  Any level, `silence/1` included, undoes it: one press of volume up re-opens
  the path. Nothing in this firmware calls it.
  """
  def disable_output(mixer \\ Amixer) do
    apply_controls(
      [
        # The amplifier goes off first, for the same reason it comes on last
        # below: no moment where a switched-on output carries a level nobody
        # asked for. `Speaker` takes no percentage -- it is a switch and
        # amixer errors on `0%` for it -- so it only gets muted.
        {"Speaker", ["mute"]},
        {"DAC", ["0%", "mute"]},
        {"Line Out", ["0%", "mute"]}
      ],
      mixer
    )
  end

  # One clause, and that is the fix. Level 0 differs from level 10 in the
  # `DAC` percentage and in nothing else: same three controls, all switched
  # on, at every level. There used to be a second clause for 0 that switched
  # them off, which is how a device that had never had its volume raised
  # could not play anything at all.
  #
  # The amplifier comes on last. On a rising level the gains are already
  # lower than where they are going, so ordering the writes this way means
  # there is no moment where a switched-on output carries a level nobody
  # asked for.
  defp controls_for(level) do
    [
      {"DAC", ["#{percent(level)}%", "unmute"]},
      {"Line Out", ["100%", "unmute"]},
      {"Speaker", ["unmute"]}
    ]
  end

  defp apply_controls(controls, mixer) do
    Enum.reduce_while(controls, :ok, fn {control, args}, _acc ->
      case mixer.set(control, args) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp play do
    Logger.info("[audio] playing one second of test signal")

    # No -P here. `-P 1` is rejected outright -- "Invalid number of periods 1",
    # exit 1, nothing played -- because the minimum is 2. It was in the first
    # version of this function, so the test would have failed silently-ish on
    # the first press and looked like a hardware problem.
    case Amixer.run("speaker-test", ["-c", "2", "-t", "sine", "-f", "440", "-l", "1"]) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, {:no_tool, "speaker-test"}}
    end
  end

  defmodule Mixer do
    @moduledoc """
    The one thing the level arithmetic needs from the outside world.

    `set(control, args)` runs one `amixer sset`. That is the whole interface,
    and it is this small on purpose: the parts of volume that can be wrong
    without hardware saying so -- clamping, the level ladder, whether every
    level leaves the output path switched on, which control is named -- are
    then testable on a laptop with a mixer that records what it was asked to
    do. The one about the switches is not a detail: the device it was wrong
    on could not play anything, and this seam is where a test says so.

    There is deliberately no `get`. Reading the mixer back to decide the next
    level would make the level depend on a parse of `amixer sget` output, and
    `MayonnaiOS.Volume` already holds it. Writing the full ladder every time
    (see `MayonnaiOS.Audio.set_level/2`) is the cheaper answer to the same
    drift problem.
    """

    @callback set(control :: String.t(), args :: [String.t()]) :: :ok | {:error, term()}
  end

  defmodule Amixer do
    @moduledoc """
    The real mixer: `amixer sset <control> <args...>`.

    Percentages rather than raw values, because `amixer` maps a percentage
    linearly onto the control's raw range and this card's `DAC` scale is
    linear in dB -- so an even ladder in percent is an even ladder in
    loudness, and nothing here has to know that the range is 0-63.
    """

    @behaviour MayonnaiOS.Audio.Mixer

    @impl MayonnaiOS.Audio.Mixer
    def set(control, args) do
      case run("amixer", ["sset", control | args]) do
        {:ok, _out} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    @doc """
    Run a tool, and report a missing one as an error rather than raising.

    `System.cmd/3` raises `ErlangError` when the executable is not on the
    path, which on a laptop is every one of these. A mixer call that takes
    down its caller because the host has no ALSA is not a useful failure.
    """
    def run(exe, args) do
      case System.cmd(exe, args, stderr_to_stdout: true) do
        {out, 0} -> {:ok, out}
        {out, status} -> {:error, {:exit, status, String.trim(out)}}
      end
    rescue
      _ -> {:error, {:no_tool, exe}}
    end
  end

  defmodule Startup do
    @moduledoc """
    Puts the mixer at the bottom of the ladder once at boot, then stops.

    Volume at its minimum with the output path switched on, so the device is
    silent until someone asks it not to be *and* anything that opens ALSA can
    still play. Those are two requirements rather than one, and the first
    version of this satisfied only the first: see `MayonnaiOS.Audio`.

    A `:transient` one-shot rather than a long-lived process: there is nothing
    to supervise afterwards, and it must not keep the supervisor busy.

    A failure here must not take the boot down -- but note what it now leaves
    behind, because this is no longer the harmless case it was. The mixer
    stays as the hardware powers on, which is every switch off, which is a
    device where every audio program fails or hangs. Hence the warning, and
    hence it says what to do about it.
    """

    use Task, restart: :transient
    require Logger

    def start_link(_opts), do: Task.start_link(__MODULE__, :run, [])

    @doc """
    Set the boot state. `mixer` is the seam the tests use.

    Taking a mixer at all is the point: the boot state is the state every
    audio program on this device has to cope with, and it was wrong for as
    long as it was only assertable by booting a device and listening.
    """
    def run(mixer \\ MayonnaiOS.Audio.Amixer) do
      case MayonnaiOS.Audio.silence(mixer) do
        :ok ->
          Logger.info("[audio] mixer at 0% with the output path open")

        other ->
          Logger.warning(
            "[audio] could not set the mixer: #{inspect(other)} -- the output path may still " <>
              "be closed, in which case playback fails with EIO until the volume is raised"
          )
      end
    end
  end
end
