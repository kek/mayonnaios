defmodule ScenicRg40xxv.Audio do
  @moduledoc """
  The audio check, built but deliberately switched off.

  Audio is the last large unverified thing on this board. It is inherited from
  the same `rg35xx-plus.dts` that got the display routing wrong, and `aplay`,
  `amixer` and `speaker-test` were put in the image specifically to settle it.

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

  ## This device powers on muted

  There is no `/var/lib/alsa/asound.state` and nothing runs `alsactl restore`,
  so the mixer returns to `DAC` off and `Line Out` 0% on every boot. A games
  machine that boots silent is broken, so `unmute/0` runs at startup and is
  not gated -- it makes no sound.

  ## The test tone

  `run/0` unmutes and then plays one second of sine, and is gated behind

      config :scenic_rg40xxv, audio_test: true

  which is now on, since audio is verified and pressing Y is deliberate.
  """

  require Logger

  # Read off the device: 'Speaker' is a switch, 'Line Out' has volume 0-31,
  # 'DAC' has volume 0-63. Names come from amixer scontrols, not guessed.
  @unmute [
    {"Speaker", ["unmute"]},
    {"DAC", ["100%", "unmute"]},
    {"Line Out", ["100%", "unmute"]}
  ]

  @doc """
  Whether the audio test has been switched on. False unless configured.
  """
  def enabled?, do: Application.get_env(:scenic_rg40xxv, :audio_test, false)

  @doc """
  Open the mixer, then play a short test. Refuses unless `enabled?/0`.

  Returns `{:error, :disabled}`, `{:error, {:no_tool, name}}` or `:ok`.
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

  Called at boot, and not gated, because **this device powers on muted**.
  `DAC` and `Line Out` both come up with their switches off and Line Out at
  0%, there is no `/var/lib/alsa/asound.state`, and nothing runs `alsactl
  restore` -- so without this a games machine boots silent every time.

  Makes no sound by itself.
  """
  def unmute do
    Enum.reduce_while(@unmute, :ok, fn {control, args}, _acc ->
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
    Opens the mixer once at boot, then stops.

    A `:transient` one-shot rather than a long-lived process: there is nothing
    to supervise afterwards, and it must not keep the supervisor busy. A
    failure here should not take the boot down either -- a silent device is
    worse than a loud one, but both are better than one that reverts.
    """

    use Task, restart: :transient
    require Logger

    def start_link(_opts), do: Task.start_link(__MODULE__, :run, [])

    def run do
      case ScenicRg40xxv.Audio.unmute() do
        :ok -> Logger.info("[audio] mixer opened")
        other -> Logger.warning("[audio] could not open the mixer: #{inspect(other)}")
      end
    end
  end
end
