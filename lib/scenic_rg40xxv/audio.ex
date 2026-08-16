defmodule ScenicRg40xxv.Audio do
  @moduledoc """
  The mixer, and the test tone that settled whether audio works at all.

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

  Raising the volume is `unmute/0`, and it is a deliberate act.

  ## The test tone

  `run/0` unmutes and plays one second of sine. It is not bound to a button.
  It was bound to Y while audio was the open question; that question is
  closed, and leaving a key on the pad that makes noise is not what the key
  is for. Call it from IEx when the mixer needs checking again:

      iex> ScenicRg40xxv.Audio.run()
  """

  require Logger

  # Read off the device: 'Speaker' is a switch, 'Line Out' has volume 0-31,
  # 'DAC' has volume 0-63. Names come from amixer scontrols, not guessed.
  @unmute [
    {"Speaker", ["unmute"]},
    {"DAC", ["100%", "unmute"]},
    {"Line Out", ["100%", "unmute"]}
  ]

  # The mirror image, and the boot state. `Speaker` takes no percentage --
  # it is a switch and amixer errors on `0%` for it -- so it only gets muted.
  @mute [
    {"Speaker", ["mute"]},
    {"DAC", ["0%", "mute"]},
    {"Line Out", ["0%", "mute"]}
  ]

  @doc """
  Whether the audio test has been switched on. False unless configured.
  """
  def enabled?, do: Application.get_env(:scenic_rg40xxv, :audio_test, false)

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
      Logger.info("[audio] test is disabled; set config :scenic_rg40xxv, audio_test: true")
      {:error, :disabled}
    end
  end

  @doc """
  Raise and unswitch the playback controls.

  A deliberate act, not a boot step. Makes no sound by itself.
  """
  def unmute, do: apply_controls(@unmute)

  @doc """
  Take every playback control to 0% and switch it off.

  This is what `Startup` does at boot. It is also what the hardware does on
  its own -- `DAC` and `Line Out` come up switched off with Line Out at 0%,
  there is no `/var/lib/alsa/asound.state` and nothing runs `alsactl restore`
  -- and doing it anyway is the point. An inherited default that happens to
  be right is indistinguishable from one that is about to stop being right,
  and this board has already been wrong twice about things read rather than
  set.
  """
  def mute, do: apply_controls(@mute)

  defp apply_controls(controls) do
    Enum.reduce_while(controls, :ok, fn {control, args}, _acc ->
      case cmd("amixer", ["sset", control | args]) do
        {:ok, _} -> {:cont, :ok}
        :error -> {:halt, {:error, {:no_tool, "amixer"}}}
      end
    end)
  end

  defp play do
    Logger.info("[audio] playing one second of test signal")

    # No -P here. `-P 1` is rejected outright -- "Invalid number of periods 1",
    # exit 1, nothing played -- because the minimum is 2. It was in the first
    # version of this function, so the test would have failed silently-ish on
    # the first press and looked like a hardware problem.
    case cmd("speaker-test", ["-c", "2", "-t", "sine", "-f", "440", "-l", "1"]) do
      {:ok, _} -> :ok
      :error -> {:error, {:no_tool, "speaker-test"}}
    end
  end

  defp cmd(exe, args) do
    {out, _status} = System.cmd(exe, args, stderr_to_stdout: true)
    {:ok, out}
  rescue
    _ -> :error
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
      case ScenicRg40xxv.Audio.mute() do
        :ok -> Logger.info("[audio] mixer muted at 0%")
        other -> Logger.warning("[audio] could not set the mixer: #{inspect(other)}")
      end
    end
  end
end
