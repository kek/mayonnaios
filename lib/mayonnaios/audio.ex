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

  ## The device boots silent, on purpose

  `Startup` sets every playback control to 0% and switches it off at boot.

  That is what the hardware does anyway -- there is no
  `/var/lib/alsa/asound.state` and nothing runs `alsactl restore`, so the
  mixer returns to `DAC` off and `Line Out` 0% on every power-on. Setting it
  explicitly rather than inheriting it is the point: a default that happens
  to be right is the exact shape of thing this board has already been wrong
  about twice, and a handheld that makes a noise nobody asked for, in a
  pocket, is a worse failure than one that starts quiet.

  Raising the volume is a deliberate act. `MayonnaiOS.Volume` makes the
  rocker on the shell that act; `unmute/0` is the same thing from IEx.

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

  `steps/0` levels plus silence, and level 0 is `mute/0` -- the boot state.
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

  `run/0` unmutes and plays one second of sine. It is not bound to a button.
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
  Open the mixer, then play a short test. Refuses unless `enabled?/0`.

  Not bound to any button -- call it from IEx. Returns `{:error, :disabled}`,
  `{:error, {:no_tool, name}}` or `:ok`.
  """
  def run do
    if enabled?() do
      with :ok <- unmute() do
        play()
      end
    else
      Logger.info("[audio] test is disabled; set config :mayonnaios, audio_test: true")
      {:error, :disabled}
    end
  end

  @doc """
  Put the mixer at `level`, between 0 and `steps/0`.

  Level 0 is the boot state: every playback control at 0% and switched off.
  Anything above it switches the same three controls on -- volume up from
  silence unmutes, because a rocker that raises a number behind a closed
  switch is the "plausible-looking but dead" failure written all over this
  board's history.

  The whole ladder is written on every call rather than only the control that
  moved. It costs two more `amixer` runs per press and it means one press
  restores a mixer that something else has changed underneath -- `unmute/0`
  from IEx, say -- instead of leaving the two disagreeing until a reboot.

  `mixer` is the seam the tests use; see `MayonnaiOS.Audio.Mixer`.
  """
  @spec set_level(integer(), module()) :: :ok | {:error, term()}
  def set_level(level, mixer \\ Amixer) when is_integer(level) do
    level |> clamp() |> controls_for() |> apply_controls(mixer)
  end

  @doc """
  Raise and unswitch the playback controls, all the way up.

  A deliberate act, not a boot step. Makes no sound by itself. This is the
  state the test tone was heard in, and it is the top of the volume ladder --
  the same thing said two ways, deliberately.

  Note that `MayonnaiOS.Volume` does not learn about this: it holds the level
  it last set, so the next press moves from there rather than from full. One
  press puts the two back in agreement.
  """
  def unmute(mixer \\ Amixer), do: set_level(@steps, mixer)

  @doc """
  Take every playback control to 0% and switch it off.

  This is what `Startup` does at boot, and what level 0 means. It is also
  what the hardware does on its own -- `DAC` and `Line Out` come up switched
  off with Line Out at 0%, there is no `/var/lib/alsa/asound.state` and
  nothing runs `alsactl restore` -- and doing it anyway is the point. An
  inherited default that happens to be right is indistinguishable from one
  that is about to stop being right, and this board has already been wrong
  twice about things read rather than set.
  """
  def mute(mixer \\ Amixer), do: set_level(0, mixer)

  # Silence. `Speaker` takes no percentage -- it is a switch and amixer errors
  # on `0%` for it -- so it only gets muted.
  #
  # The amplifier goes off first and comes on last, in the clause below. On a
  # rising level the gains are already lower than where they are going, so
  # ordering the writes this way means there is no moment where a switched-on
  # output carries a level nobody asked for.
  defp controls_for(0) do
    [
      {"Speaker", ["mute"]},
      {"DAC", ["0%", "mute"]},
      {"Line Out", ["0%", "mute"]}
    ]
  end

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
    without hardware saying so -- clamping, the level ladder, whether raising
    from silence also unswitches, which control is named -- are then testable
    on a laptop with a mixer that records what it was asked to do.

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
    Closes the mixer once at boot, then stops.

    Every playback control to 0% and off, so the device is silent until
    someone asks it not to be.

    A `:transient` one-shot rather than a long-lived process: there is nothing
    to supervise afterwards, and it must not keep the supervisor busy. A
    failure here should not take the boot down either -- it would leave the
    mixer at whatever the hardware chose, which today is the same thing.
    """

    use Task, restart: :transient
    require Logger

    def start_link(_opts), do: Task.start_link(__MODULE__, :run, [])

    def run do
      case MayonnaiOS.Audio.mute() do
        :ok -> Logger.info("[audio] mixer muted at 0%")
        other -> Logger.warning("[audio] could not set the mixer: #{inspect(other)}")
      end
    end
  end
end
