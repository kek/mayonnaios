defmodule ScenicRg40xxv.Audio do
  @moduledoc """
  The audio check, built but deliberately switched off.

  Audio is the last large unverified thing on this board. It is inherited from
  the same `rg35xx-plus.dts` that got the display routing wrong, and `aplay`,
  `amixer` and `speaker-test` were put in the image specifically to settle it.

  What is already known, from reading the device and making no sound:

    * the codec bound -- `aplay -l` lists *card 0: Codec [H616 Audio Codec]*,
      and `/dev/snd/pcmC0D0p` exists, so the "no card" failure is ruled out
    * the mixer is muted -- `DAC` is at 100% with its switch **off**, and
      `Line Out` is at 0% and off

  That second point is the whole reason this module is careful. The plan says
  it in as many words: silence is far more likely to be a muted mixer than
  wrong device-tree routing, and reading silence as routing evidence sends the
  next person into the DTS for nothing. The mixer state above is now measured,
  so a test that plays into a muted mixer would produce exactly that false
  conclusion.

  ## Why nothing plays yet

  Making noise is not a thing to do to someone's device while they are away
  from it, so this is gated:

      config :scenic_rg40xxv, audio_test: true

  It defaults to `false`, and with it `false` every entry point here refuses
  and returns `{:error, :disabled}`. Nothing in this application opens the
  PCM until that is flipped by hand.

  ## What it does once enabled

  `run/0` unmutes first and then plays, because the two together answer the
  question and either alone does not:

    1. `DAC` switch on, `Line Out` switch on and raised, `Speaker` on
    2. one second of `speaker-test`

  Then the result means something. Sound is a pass. Silence, *with the mixer
  known to be open*, is the first real evidence that the routing inherited
  from the RG35XX Plus does not describe this board.
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
  Raise and unswitch the playback controls. Makes no sound by itself, but is
  still gated -- it changes device state, and the point of the gate is that
  the device is left as found until someone asks otherwise.
  """
  def unmute do
    if enabled?() do
      Enum.reduce_while(@unmute, :ok, fn {control, args}, _acc ->
        case cmd("amixer", ["sset", control | args]) do
          {:ok, _} -> {:cont, :ok}
          :error -> {:halt, {:error, {:no_tool, "amixer"}}}
        end
      end)
    else
      {:error, :disabled}
    end
  end

  defp play do
    Logger.info("[audio] playing one second of test signal")

    case cmd("speaker-test", ["-c", "2", "-t", "sine", "-f", "440", "-l", "1", "-P", "1"]) do
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
end
