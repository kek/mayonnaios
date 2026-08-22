defmodule MayonnaiOS.Volume do
  @moduledoc """
  The volume rocker, and the level it moves.

  The two keys on the top edge have been seen arriving as input events since
  the diagnostics screen started counting them -- `KEY_VOLUMEUP` and
  `KEY_VOLUMEDOWN` on `gpio-keys-volume`, incrementing a counter on the panel
  when pressed. Nothing acted on them. This process is the thing that acts:
  each press moves a level, and each level is written to the mixer by
  `MayonnaiOS.Audio.set_level/2`.

  ## Where volume lives, and why it is the ALSA control

  Two candidates, and only one of them is reachable from here.

  RetroArch has its own volume -- `audio_volume`, applied as
  `DB_TO_GAIN(audio_volume)` in `audio_driver_flush`. It is **in dB**, and the
  `0.000000` in the installed config is `0 dB`, which is unity gain and the
  shipped default. It is not a muted player, and it is not why the buttons did
  nothing; reading that zero as silence is the same mistake as reading a
  config file as the program. It is also only reachable through RetroArch's
  own menu and hotkeys, and it does nothing for the launcher.

  The ALSA control is the other one, and it is the whole device: the codec's
  gain, applied to whatever is playing, whoever is playing it. ALSA's control
  interface is not the PCM -- `/dev/snd/controlC0` is opened separately from
  `/dev/snd/pcmC0D0p`, and a program holding a playback stream is not holding
  the mixer.

  So the rocker moves the ALSA control. One volume, in the launcher and in a
  game, and no per-program settings to keep in step.

  Be clear about which half of that is established. The RetroArch reading is
  from its source -- `DB_TO_GAIN(audio_volume)` in `audio_driver_flush`, and
  `DEFAULT_AUDIO_VOLUME 0.0f` commented "0.0 dB == unity gain" in
  `config.def.h`. The separation of the control interface from the PCM is
  ALSA's design and not something anyone has demonstrated on *this* board:
  nobody has yet moved the mixer while RetroArch had a game running and
  listened to the result. That is the check to make, and it is a check with
  ears rather than one this code can make for itself.

  ## Why this process, and not the Diagnostics one

  `gpio-keys-volume` is opened here *as well as* in `MayonnaiOS.Diagnostics`,
  which counts presses for the panel. That is not a mistake and not a race:
  evdev is not exclusive unless a reader asks for `EVIOCGRAB`, and
  `InputEvent` only asks when told to (`grab: false` is its default, checked
  in its port source). Both readers get every event.

  The same fact answers the more interesting question, which is whether the
  rocker keeps working while RetroArch has the screen. RetroArch reads the
  gamepad through udev, so it opens this device too -- and `EVIOCGRAB` does
  not appear anywhere in RetroArch 1.22.2, the version installed here. Its
  `grab_mouse` is a pointer grab under X11 and Wayland, not an evdev one. So
  it never takes a device away from this process.

  Two openers rather than one owner because the alternative is worse in the
  way that matters. Diagnostics is a read-only observer of hardware -- that is
  its entire job -- and having it drive the mixer would put a control path
  inside the process whose failure mode is meant to be "the readout is stale".
  And moving the device out of Diagnostics would mean the volume counters on
  the panel, which are how the rocker was verified in the first place, stop
  working whenever this process is not running.

  ## What a press does

  One press, one level. Autorepeat (`value` 2) is ignored, the same as in
  `MayonnaiOS.Launcher`: holding the rocker does not ramp. That is a decision
  rather than an omission -- `gpio-keys` only emits repeats when its device
  tree node says `autorepeat`, this one has not been observed emitting any,
  and code for an event nobody has seen is the kind of plausible-looking thing
  this board keeps punishing. `InputEvent` can turn repeats on itself
  (`repeat_delay`/`repeat_period`, an `EVIOCSREP` on the shared fd) if it
  turns out to be wanted, and that would change what Diagnostics sees too.

  Level 0 is silence and nothing else: the `DAC` at 0%, with the output path
  still switched on. That is the state `MayonnaiOS.Audio.Startup` leaves at
  boot, so this process starts believing the mixer rather than asserting
  anything over it.

  Level 0 used to mean muted as well, and that was a bug with a much larger
  blast radius than a volume control has any business having. The switches
  are the route to the sink, ALSA powers the DAC only when the route is
  complete, so closing them makes playback *impossible* rather than
  inaudible: a write to the PCM returns `EIO`, and a program that waits for
  buffer space instead waits in `poll()` for ever.

  The device was found demonstrating exactly that -- a game frozen mid-play,
  the ring buffer holding `[volume] level 0/10 (0%)` and the PCM's `hw_ptr`
  stopping in the same second. The rocker had walked down to the bottom of its
  travel, which is the one thing a volume control must always be allowed to
  do. `MayonnaiOS.Audio` has the measurements; the part that belongs here is
  that this process no longer has a level that can take the audio path away
  from whatever is playing.

  Which leaves one notion of silence in one place. `Audio.disable_output/1`
  closes the path and is not a level, not the boot state, and not reachable
  from these two keys.

  ## No on-screen indicator, yet

  Deliberately none. The level is visible on the diagnostics screen already --
  the `DAC` row is the control this moves, shown as a percentage and an
  on/off -- and a transient overlay belongs with the shared top bar rather
  than being invented twice.
  """

  use GenServer
  require Logger

  alias MayonnaiOS.Audio

  # The name the driver gives the rocker, and the path it has had. Looked up
  # by name because /dev/input numbering is probe order; see `MayonnaiOS.Input`.
  @device_name "gpio-keys-volume"
  @device "/dev/input/event1"

  # Read off the hardware, not the device tree: these are the atoms
  # `InputEvent` decodes KEY_VOLUMEUP (115) and KEY_VOLUMEDOWN (114) to, and
  # they are the atoms the diagnostics counters have been incrementing on real
  # presses. The gamepad's codes needed pressing to establish; these did not
  # turn out to lie, but they were checked the same way.
  @up :key_volumeup
  @down :key_volumedown

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The level the mixer was last put at, from 0 to `MayonnaiOS.Audio.steps/0`.
  """
  def level(server \\ __MODULE__), do: GenServer.call(server, :level)

  @doc """
  One step up, or down, without pressing anything. Returns the new level.
  """
  def up(server \\ __MODULE__), do: GenServer.call(server, {:step, +1})
  def down(server \\ __MODULE__), do: GenServer.call(server, {:step, -1})

  @doc """
  Go straight to a level. Clamped, so `set(99)` is the top of the ladder.
  """
  def set(server \\ __MODULE__, level) when is_integer(level),
    do: GenServer.call(server, {:set, level})

  @impl GenServer
  def init(opts) do
    device = Keyword.get(opts, :device, MayonnaiOS.Input.find(@device_name, @device))

    case open_device(device) do
      {:ok, _pid} ->
        Logger.info("[volume] watching #{device}: #{Audio.steps()} levels above silence")

      {:error, reason} ->
        # No rocker is not a reason to fail the boot. Everything else about
        # the device still works, and `up/0` from IEx still works.
        Logger.warning("[volume] #{device} unavailable: #{inspect(reason)}")
    end

    # Silence, because that is what `MayonnaiOS.Audio.Startup` has just set.
    # Nothing is written here: the boot state is already correct, and
    # re-asserting it would make this process the second thing that decides
    # how loud a freshly booted device is.
    #
    # Note that this is no longer also what the hardware powers on as. The
    # hardware comes up with the output path closed and `Startup` opens it, so
    # believing the mixer here is believing `Startup` -- and if `Startup`
    # failed, its warning is the thing that says so. Writing a level from here
    # to be sure would hide that.
    {:ok, %{level: Keyword.get(opts, :level, 0), mixer: Keyword.get(opts, :mixer, Audio.Amixer)}}
  end

  # The same guard the Launcher uses, and for the same reason: InputEvent's
  # port binary is only built on Linux, so `start_link/1` *raises* on a macOS
  # host rather than returning an error, which inside a linked start would
  # take this process down at boot instead of degrading to "no rocker".
  defp open_device(device) do
    if File.exists?(device), do: InputEvent.start_link(device), else: {:error, :enoent}
  end

  @impl GenServer
  def handle_call(:level, _from, state), do: {:reply, state.level, state}

  def handle_call({:step, delta}, _from, state) do
    state = apply_level(state, state.level + delta)
    {:reply, state.level, state}
  end

  def handle_call({:set, level}, _from, state) do
    state = apply_level(state, level)
    {:reply, state.level, state}
  end

  @impl GenServer
  # One report, one move. The presses in a report are summed rather than
  # applied one at a time so that a report carrying both keys -- which is what
  # someone squeezing the rocker in the middle produces -- is a no-op instead
  # of two writes that fight, and so that a press is one round of `amixer`
  # rather than three.
  def handle_info({:input_event, _device, events}, state) do
    case Enum.reduce(events, 0, &delta/2) do
      0 -> {:noreply, state}
      delta -> {:noreply, apply_level(state, state.level + delta)}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Value 1 only. 0 is a release and 2 is autorepeat; see the moduledoc.
  defp delta({:ev_key, @up, 1}, acc), do: acc + 1
  defp delta({:ev_key, @down, 1}, acc), do: acc - 1
  defp delta(_event, acc), do: acc

  # The level is stored whatever the mixer says, so a card that has gone away
  # does not leave the rocker stuck at the level it failed on -- and the log
  # line is a warning, because a volume key that cannot reach the mixer is a
  # real fault and not something to find out about by listening.
  defp apply_level(state, level) do
    level = Audio.clamp(level)

    case Audio.set_level(level, state.mixer) do
      :ok ->
        Logger.info("[volume] level #{level}/#{Audio.steps()} (#{Audio.percent(level)}%)")

      {:error, reason} ->
        Logger.warning("[volume] level #{level} not set: #{inspect(reason)}")
    end

    %{state | level: level}
  end
end
