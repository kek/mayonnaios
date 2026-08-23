defmodule MayonnaiOS.Cores do
  @moduledoc """
  Libretro cores: a catalogue, an installer, and the directory RetroArch is
  pointed at.

  ## Why the application owns the core directory

  RetroArch reads cores from exactly one `libretro_directory`. The obvious
  choice is the one inside the RetroArch bundle, `lib/libretro`, and it is
  wrong: bundles are installed per version and swapped by moving a symlink, so
  everything in that directory belongs to that version and goes away with it.
  A core installed there survives until the next RetroArch upgrade and then
  silently is not there any more.

  A core added by hand to `.../current/lib/libretro` had exactly that
  property, which is how this came up.

  So RetroArch is told nothing at all, and the directory it reads is its own
  default: `platform_unix.c` joins `cores` onto `$XDG_CONFIG_HOME/retroarch`,
  or onto `$HOME/.config/retroarch` when that is unset. This module fills that
  directory with symlinks.

  ## Why nothing is configured, and why that needs enforcing

  Not naming a directory is deliberate, for two reasons that are narrower and
  worse than "one place is tidier than two".

  `libretro_directory` is **not validated on load**. `savefile_directory` and
  `savestate_directory` are -- a value naming a directory that does not exist
  is dropped with a warning -- but the core directory is taken verbatim. Point
  it somewhere absent and RetroArch shows an empty core list and says nothing
  about why.

  And `--appendconfig` is merged into the same config handle *before* the
  settings are read from it, so a value the bundle appends is indistinguishable
  from one the player set, and is written into the main config on exit. A
  setting therefore outlives the bundle that introduced it. Those two together
  produced both failures this arrangement has had: first cores read out of a
  stale bundle, then -- once the directory that bundle named was gone -- no
  cores at all, from a value no file in any repository still contained.

  Which is why `clear_stale_directory/0` exists. Removing the setting from the
  bundle does not remove it from a device that already ran an older one, so the
  invariant has to be asserted on the device rather than merely shipped.

  What stays ours is the *contents*: the real `.so` files live in the bundle
  and in `core_root`, and only symlinks go into the core directory. `sync/0`
  rebuilds it from the two places cores actually come from:

    * whatever the installed RetroArch bundle ships in `lib/libretro`
    * each core bundle under `/root/cores/<name>/current/`

  Symlinks rather than copies because `dlopen` follows them, they cost
  nothing, and they track `current` -- so upgrading a core is a symlink move
  two levels down and this directory needs no maintenance.

  Rebuilding rather than patching: `sync/0` clears the directory of the links
  it manages and lays them down again. Anything that disappeared upstream
  disappears here, which is the behaviour that keeps a dangling `.so` from
  showing in RetroArch's core list and failing at load.

  ## Why cores are not downloaded by RetroArch

  RetroArch's own online updater is compiled out of this build
  (`--disable-online_updater`, and networking with it). Enabling it would mean
  linking a network stack into RetroArch and trusting the libretro buildbot's
  cores to match this device's glibc and sysroot -- which they do not, because
  this system is built from its own Buildroot.

  Cores are therefore built by `coldcuts` against the same sysroot as
  everything else and published as their own small tarballs, and installed
  here by the mechanism already proven for RetroArch itself: fetch, verify the
  SHA-256 *before* unpacking, install to a versioned directory, move a
  symlink. `MayonnaiOS.Bundle` does all of that; this module only decides
  where and what.

  The catalogue lives in config, with the firmware, for the same reason the
  RetroArch spec does: a checksum served from beside the file it describes is
  not evidence of anything.

  ## The two things in here that are not about cores

  `write_append_config/0` also writes `audio_sync = "false"` and an
  `autosave_interval`, neither of which has anything to do with cores and both
  of which have everything to do with the mechanism this module already owns:
  the one file appended after the bundle's, rewritten every boot, paired with a
  boot-time scrub of the player's config so that nothing it says can outlive
  it. That pairing is the only way this firmware can assert a RetroArch setting
  and still be able to take it back, and it exists here because
  `libretro_directory` needed it first. Splitting it across two modules would
  mean two writers of one file. See that function.
  """

  require Logger

  alias MayonnaiOS.Bundle

  # RetroArch's own config, the file it writes its settings back into on exit.
  # Overridable so the tests can point somewhere writable; the device never
  # needs to.
  @retroarch_config "/root/.config/retroarch/retroarch.cfg"

  # Seconds between SRAM autosaves. The number is argued in
  # `write_append_config/0`; overridable so a test can assert that the value
  # travels rather than hard-coding it twice.
  @autosave_interval 10

  @doc """
  Where core bundles are installed, one versioned directory per core.
  """
  def root, do: Application.get_env(:mayonnaios, :core_root, "/root/cores")

  @doc """
  The flat directory RetroArch reads cores from.

  RetroArch's own default, not a choice -- which is why nothing sets
  `libretro_directory` and why `clear_stale_directory/0` takes anything that
  does back out.
  """
  def dir, do: Application.get_env(:mayonnaios, :core_dir, "/root/.config/retroarch/cores")

  @doc """
  The core catalogue, keyed by core name.
  """
  def catalogue, do: Application.get_env(:mayonnaios, :cores, %{})

  @doc """
  RetroArch's own config file -- the one it writes its settings back into.

  Not a directory this application owns, which is exactly why it is named in
  one place.
  """
  def retroarch_config do
    Application.get_env(:mayonnaios, :retroarch_config, @retroarch_config)
  end

  @doc """
  Seconds between SRAM autosaves, as `write_append_config/0` will assert it.

  See that function for why the number is what it is.
  """
  def autosave_interval do
    Application.get_env(:mayonnaios, :retroarch_autosave_interval, @autosave_interval)
  end

  @doc """
  Remove `libretro_directory` from RetroArch's main config unless it already
  names `dir/0`.

  Necessary rather than tidy. RetroArch persists its settings on exit and
  cannot tell an appended value from one the player chose, so a device that
  ever ran a bundle naming a core directory keeps that value after the bundle
  stops naming one. Shipping the fix does not undo it on the device that needs
  it; this does. The moduledoc has the full account.

  Conservative in both directions. A value that already names `dir/0` is left
  alone: RetroArch wrote it itself, from the default, and it is correct. A
  missing or unreadable config is not a failure either -- it means RetroArch
  has not run yet, which is the normal state of a freshly flashed device.

  The rewrite goes through a temporary file and a rename because the file being
  edited is the player's own settings, six figures of them, and a write torn by
  a pulled power cable would lose the lot.
  """
  def clear_stale_directory(path \\ nil) do
    strip(path || retroarch_config(), "libretro_directory", &stale_directory?/1)
  end

  @doc """
  Remove `audio_sync` from RetroArch's main config, whatever it says.

  This is the other half of `write_append_config/0`'s `audio_sync = "false"`,
  and it is the half that makes the guard removable. The full account of why
  the guard exists is on that function; this is how it is taken back out.

  Unconditional, unlike `clear_stale_directory/1`, and the asymmetry is the
  point. A `libretro_directory` that already names `dir/0` is *correct*, so
  leaving it costs nothing. A persisted `audio_sync` is never correct and
  never load-bearing: the value that decides the launch is the one in
  `append_config/0`, which is merged last on every launch and rewritten on
  every boot. The copy in the player's config is only ever a fossil of a
  launch that has already happened.

  So it goes, every boot. Which means the day the codec is trustworthy,
  deleting the line from `write_append_config/0` is genuinely enough: the next
  boot removes the fossil and RetroArch falls back to its own default
  (`audio_sync = true`). No device is left carrying a setting no file in any
  repository still contains -- which is exactly what happened with
  `libretro_directory`, and cost two rounds of debugging to find.

  The price is worth stating plainly: this firmware owns `audio_sync`. A value
  set in RetroArch's own audio menu will not survive a reboot. That is a real
  loss of control over one setting, accepted because the alternative failure
  is a frozen game and because nobody can reach that menu while the game is
  frozen.
  """
  def clear_persisted_audio_sync(path \\ nil) do
    strip(path || retroarch_config(), "audio_sync", &audio_sync?/1)
  end

  @doc """
  Remove `autosave_interval` from RetroArch's main config, whatever it says.

  The other half of the `autosave_interval` that `write_append_config/0`
  writes, and the half that makes the setting removable. Unconditional for the
  same reasons as `clear_persisted_audio_sync/1` -- which has the argument for
  why a scrub is asymmetric with `clear_stale_directory/1` -- plus one that is
  specific to this setting: the fossil that caused today's loss was
  `autosave_interval = "0"`, RetroArch's own default, and nothing in a config
  file distinguishes it from a number the player chose.

  So it goes, every boot. Which means the day this policy changes, editing the
  number in `write_append_config/0` -- or deleting the line -- is genuinely
  enough: the next boot removes the fossil and RetroArch falls back to what
  the appended file says, or to its own default when the line is gone.

  The price, the same shape as the one above: this firmware owns
  `autosave_interval`, and a value set in RetroArch's own Saving menu will not
  survive a reboot. Accepted because the setting being wrong costs a save file,
  and the person it costs it to is the one who cannot see that it is wrong.
  """
  def clear_persisted_autosave(path \\ nil) do
    strip(path || retroarch_config(), "autosave_interval", &autosave_interval?/1)
  end

  # One read, one rewrite, for any setting this application takes back out of
  # the player's config. Shared because the mechanism is the same and the
  # policy -- which lines go -- is the only thing that differs.
  defp strip(path, setting, drop?) do
    case File.read(path) do
      {:ok, contents} ->
        {stale, keep} =
          contents
          |> String.split("\n")
          |> Enum.split_with(drop?)

        if stale == [] do
          {:ok, :unchanged}
        else
          rewrite(path, setting, keep, Enum.map(stale, &value_of(setting, &1)))
        end

      {:error, :enoent} ->
        {:ok, :no_config}

      {:error, reason} ->
        Logger.warning("[cores] could not read #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp rewrite(path, setting, lines, cleared) do
    tmp = path <> ".mayonnaios"

    with :ok <- File.write(tmp, Enum.join(lines, "\n")),
         :ok <- File.rename(tmp, path) do
      Logger.info("[cores] cleared #{setting} #{inspect(cleared)} from #{path}")
      {:ok, {:cleared, cleared}}
    else
      {:error, reason} ->
        File.rm(tmp)
        Logger.warning("[cores] could not rewrite #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp stale_directory?(line) do
    case value_of("libretro_directory", line) do
      nil -> false
      # Expanded before comparing: RetroArch writes the value back with the
      # home directory abbreviated to `~`, so the string it saves for the
      # default is never equal to the absolute path this module uses.
      value -> Path.expand(value) != Path.expand(dir())
    end
  end

  # Any `audio_sync` at all, whatever it is set to. See
  # `clear_persisted_audio_sync/1` for why this one is unconditional and the
  # directory one is not.
  defp audio_sync?(line), do: value_of("audio_sync", line) != nil

  # Any `autosave_interval` at all, including one that agrees with what this
  # firmware asks for: the appended file is what decides a launch, so the copy
  # in the player's config is a fossil even when it matches.
  defp autosave_interval?(line), do: value_of("autosave_interval", line) != nil

  # One `key = value` line, or nil if this line is not that key.
  #
  # Anchored on both sides of the key, which is not fussiness: RetroArch's
  # config holds `libretro_info_path`, `libretro_log_level`,
  # `core_updater_buildbot_cores_url`, `savestate_auto_save` next to
  # `autosave_interval`, and a hundred others, and a loose match would edit
  # lines this application knows nothing about.
  defp value_of(setting, line) do
    case Regex.run(~r/^\s*#{Regex.escape(setting)}\s*=\s*"?(.*?)"?\s*$/, line) do
      [_, value] -> value
      nil -> nil
    end
  end

  @doc """
  What the UI needs to show about cores: everything catalogued, plus anything
  actually present that is not.

  The two lists are not the same, and the difference is the interesting part.
  A core can be usable without being catalogued -- the ones the RetroArch
  bundle ships are exactly that -- and showing only the catalogue would tell
  someone that a core they can already play games with is not there.

  So `available` is what RetroArch will find, and `installed` is whether this
  device installed it as its own bundle at the catalogued version. Reporting
  one of those as the other is how a UI ends up offering "Install" for
  something that already works.
  """
  def list do
    linked = MapSet.new(links())

    catalogued =
      Enum.map(catalogue(), fn {key, spec} ->
        %{
          key: to_string(key),
          name: spec.name,
          label: Map.get(spec, :label, spec.name),
          systems: Map.get(spec, :systems, []),
          version: spec.version,
          installed: Bundle.installed?(spec, root()),
          available: MapSet.member?(linked, so_name(spec.name))
        }
      end)

    known = MapSet.new(catalogued, &so_name(&1.name))

    uncatalogued =
      linked
      |> Enum.reject(&MapSet.member?(known, &1))
      |> Enum.map(fn so ->
        name = String.replace_suffix(so, "_libretro.so", "")

        %{
          key: name,
          name: name,
          label: name,
          systems: [],
          # Nothing here declares a version. The .so has no version to read and
          # inventing one -- from the bundle, say -- would be a claim about
          # something this function did not look at.
          version: nil,
          installed: false,
          available: true
        }
      end)

    Enum.sort_by(catalogued ++ uncatalogued, & &1.label)
  end

  @doc """
  Fetch, verify and install a core, then relink the core directory.

  Returns whatever `Bundle.install/2` returned; `sync/0` runs on success only,
  because there is nothing new to link otherwise.
  """
  def install(key) when is_atom(key) or is_binary(key) do
    case fetch_spec(key) do
      nil ->
        {:error, :unknown_core}

      spec ->
        case Bundle.install(spec, root: root()) do
          {:ok, result} ->
            sync()
            {:ok, result}

          error ->
            error
        end
    end
  end

  @doc """
  Where the override config lives: one setting, naming `dir/0`.

  Under `/root` rather than in the read-only rootfs because it is generated
  from `dir/0` rather than written by hand. One place decides where cores
  go, and both the symlinks and this file follow it.
  """
  def append_config do
    Application.get_env(
      :mayonnaios,
      :retroarch_append_config,
      "/root/.config/retroarch/mayonnaios.cfg"
    )
  end

  @doc """
  Write the override config, so that a launch ends up reading `dir/0`
  whatever the bundle has to say about it.

  ## Why this exists when nothing is supposed to configure the directory

  The plan was that RetroArch would be told nothing and would use its own
  default, which is `dir/0`. That plan has one flaw, and the device found it:
  the RetroArch bundle's own config sets `libretro_directory` -- the installed
  one names `/root/retroarch/cores`, in a comment block referring to a module
  this project renamed away from -- and the launcher passes that file with
  `--appendconfig` on every single launch.

  Against that, `clear_stale_directory/0` cannot win. It runs at boot and
  removes the value from the player's config; the launch then appends it
  again, RetroArch reads it, finds a directory with nothing in it, shows an
  empty core list, and writes the value back into the player's config on
  exit. Every boot repaired it and every launch broke it again.

  So the invariant is asserted where it is actually decided. `--appendconfig`
  takes a `|`-separated list and each file is merged in turn, so a second file
  after the bundle's has the last word. That is the same reasoning
  `clear_stale_directory/0` is built on -- a bundle is a separately versioned
  artifact and cannot be relied on to *not* say something -- applied to the
  launch rather than to the boot.

  Setting the value to the directory RetroArch would have defaulted to is not
  a contradiction of the "configure nothing" rule so much as its enforcement:
  the value written here is the default, and `clear_stale_directory/0`
  deliberately leaves a config naming `dir/0` alone.

  ## The other settings: `audio_sync = "false"` and `autosave_interval`

  Two settings that are not about cores, here because this is the one file
  whose contents this firmware can both assert and retract. They are otherwise
  unrelated: one stops a hang, the other stops a save being thrown away.

  ### `audio_sync = "false"`

  A guard, not a preference, and the only setting in this firmware that is
  here to stop a *hang* rather than to name a path.

  RetroArch's ALSA output is blocking by default: when the buffer is full it
  waits in `poll()` for the card to make space. If the card never does, it
  waits for ever -- not a dropout, a frozen game on a frozen screen, with the
  DRM master still held so that every later launch fails with `[KMS] Error
  when switching mode` and looks like a display bug. That is what a codec with
  its output path switched off did to this device, and `MayonnaiOS.Audio` is
  the fix for the cause. This is the belt to that braces: with `audio_sync`
  off, RetroArch sets the driver non-blocking and drops samples instead of
  waiting, so a stalled codec costs audio rather than the machine.

  Read that as reasoning about RetroArch's audio driver, not as a measurement.
  What is measured is the hang and the codec; nobody has yet watched a game
  survive a deliberately stalled card with this setting on, because producing
  one means playing audio on a device whose owner has asked for silence.

  ### `autosave_interval = "10"`

  The device was found with `autosave_interval = "0"` in the player's config,
  which is RetroArch's own default and means *never autosave*. With it off,
  the SRAM `.srm` is written when content closes cleanly and at no other time,
  so every kill, every hang and every pulled power cable discards the whole
  session -- including in-game saves the player made at a save point an hour
  earlier. That is not a hypothetical: it happened repeatedly in one
  afternoon, to a Chrono Trigger file, while a hung RetroArch was being
  SIGKILLed to diagnose the audio fault the setting above is the belt for.

  This device cannot rely on a clean close. It is switched off by pulling the
  power, there is no clean shutdown in normal use, and a program that hangs
  holding DRM master has to be killed -- which `MayonnaiOS.Launcher` now does
  properly, and which is exactly the operation that used to cost the save. A
  save mechanism that only runs on a clean exit is a save mechanism that runs
  on the good days.

  Read the guarantee carefully, because it is narrower than "you lose at most
  ten seconds of play": SRAM holds what the *game* has written to its
  battery-backed memory, so what is being protected is the player's own
  in-game saves, not the walk between them. What ten seconds buys is that an
  in-game save is on its way to the card about ten seconds later instead of
  surviving only if RetroArch is allowed to exit cleanly.

  Ten rather than sixty because the cost is bounded by the game rather than by
  the clock: RetroArch's autosave thread compares the SRAM against its last
  copy and writes only when it differs, so a shorter interval does not mean
  more writes on a card that times out on erase (`mmc_erase: group start error
  -110`, the reason `/root` is mounted `nodiscard` -- see
  `MayonnaiOS.AppPartition`). It means the write happens sooner after the
  game's own save, and 8 KB of `.srm` is one f2fs write either way. Ten
  rather than one because a burst of SRAM writes -- some games rewrite a
  checksum region repeatedly -- should coalesce into one write, and because
  ten seconds of extra exposure is not worth a tenfold write rate in the
  pathological case.

  That the writes are change-gated is read from RetroArch's autosave thread,
  not measured here. If it turns out to write unconditionally, the number to
  change is `@autosave_interval` and nothing else moves.

  What this setting does *not* do is make the write durable. RetroArch flushes
  the file to the kernel and does not fsync it, so an autosaved `.srm` lives
  in the page cache until f2fs writes it back on its own schedule -- and this
  device has no `sync` binary and no clean shutdown. `MayonnaiOS.Saves` is the
  other half of that, and it is the half that can only run once the program
  that owns the file is confirmed gone.

  ### What was considered and not done: a save state on stop

  `savestate_auto_save = "true"` would write a full machine state when content
  closes, and `savestate_auto_load` would put the player back exactly where
  they were. It is rejected, and not narrowly.

  It writes on a *clean close*, which is the code path that already works and
  the one that was never the problem: a SIGKILLed or unplugged RetroArch does
  not reach it either. So it adds nothing to the failure being fixed, while
  adding a multi-megabyte write to every ordinary exit on a card whose erase
  times out. And a state is tied to the core that wrote it -- upgrade
  snes9x2010 and the automatic load either fails or, worse, restores something
  subtly wrong -- so it would make a core upgrade able to break a game that
  had been fine, in exchange for convenience nobody asked for.

  SRAM is the opposite of that: 8 KB, the format the game itself defined, and
  portable across cores and RetroArch versions. It is the thing worth making
  durable.

  ## Why here, and not in the bundle or on the command line

  There is no command line for either -- RetroArch takes settings from config
  files -- so the only question is which file. It cannot be the bundle's:
  bundles are separately versioned artifacts, a value one appends is
  indistinguishable from one the player chose, and RetroArch writes it into
  the player's own config on exit. That is how `libretro_directory` outlived
  every file that named it. Anything a bundle asserts, no later bundle can
  withdraw.

  This file has neither problem, and both halves matter:

    * it is rewritten from this function on every boot, so what it says is
      whatever this firmware currently says, and
    * `clear_persisted_audio_sync/1` and `clear_persisted_autosave/1` take
      those settings out of the player's config on every boot, so the copies
      RetroArch persists on exit are scrubbed before the next launch reads
      anything.

  Retraction is therefore editing or deleting one line in this function. There
  is no device to go and repair afterwards, which is the property
  `libretro_directory` did not have.

  One file with two settings rather than a second file with one, because the
  file has exactly one writer and that is worth keeping. Two modules writing
  one path is a clobber waiting for the boot order to change; and the
  `--appendconfig` argument in `config :mayonnaios, :programs` names this path
  once, so a second file would also mean editing the launch arguments to add
  it.
  """
  def write_append_config do
    path = append_config()

    contents = """
    libretro_directory = "#{dir()}"
    audio_sync = "false"
    autosave_interval = "#{autosave_interval()}"
    """

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, contents) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("[cores] could not write #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Rebuild the core directory from the RetroArch bundle and the installed
  core bundles.

  Idempotent, and safe to call when nothing is installed -- it then produces
  an empty directory, which is a correct answer and not an error.

  Returns the list of core filenames now present.
  """
  def sync do
    target = dir()
    File.mkdir_p!(target)

    # Clear first. A core that was uninstalled, or that vanished with a
    # RetroArch upgrade, must not be left behind as a dangling symlink:
    # RetroArch lists the directory and would offer it, then fail at dlopen
    # with an error about the file rather than about the install.
    for name <- File.ls!(target), String.ends_with?(name, ".so") do
      File.rm(Path.join(target, name))
    end

    sources()
    |> Enum.each(fn source ->
      link = Path.join(target, Path.basename(source))
      # Relative to nothing -- the target is absolute, and these paths run
      # through `current`, which is itself a symlink that moves on upgrade.
      case File.ln_s(source, link) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("[cores] could not link #{source}: #{inspect(reason)}")
      end
    end)

    found = links()
    Logger.info("[cores] #{length(found)} core(s) in #{target}")
    found
  end

  @doc """
  The core filenames currently in the core directory.
  """
  def links do
    case File.ls(dir()) do
      {:ok, names} -> names |> Enum.filter(&String.ends_with?(&1, ".so")) |> Enum.sort()
      {:error, _} -> []
    end
  end

  # Everywhere a core can come from, most-specific last so an installed core
  # bundle wins over the copy RetroArch happened to ship.
  defp sources do
    (bundled_cores() ++ installed_cores())
    |> Enum.reduce(%{}, fn path, acc -> Map.put(acc, Path.basename(path), path) end)
    |> Map.values()
    |> Enum.sort()
  end

  defp bundled_cores do
    case Bundle.current("retroarch") do
      nil -> []
      current -> Path.wildcard(Path.join([current, "lib", "libretro", "*.so"]))
    end
  end

  defp installed_cores do
    catalogue()
    |> Map.values()
    |> Enum.flat_map(fn spec ->
      case Bundle.current(spec.name, root()) do
        nil -> []
        current -> Path.wildcard(Path.join(current, "*.so"))
      end
    end)
  end

  defp fetch_spec(key) when is_binary(key) do
    Enum.find_value(catalogue(), fn {k, spec} -> if to_string(k) == key, do: spec end)
  end

  defp fetch_spec(key), do: catalogue()[key]

  defp so_name(name), do: "#{name}_libretro.so"

  defmodule Startup do
    @moduledoc """
    Asserts the core arrangement once at boot: RetroArch's config names no core
    directory, carries neither an `audio_sync` nor an `autosave_interval` of its
    own, and the default core
    directory holds a link per core.

    Cheap -- a listing and a handful of symlinks -- and it is the step that
    makes a RetroArch upgrade not lose the installed cores: `current` has
    moved by the time this runs, so the links follow it.

    Boot is the right moment for the config half too. RetroArch is not running
    then, so there is no writer to race, and the value being removed is one
    that would otherwise send it looking for cores in a directory nothing
    fills.

    `:transient`, and a failure here must not take the boot down. A device
    with no cores still boots to a menu and still has SSH; one that refuses to
    start has neither.
    """

    use Task, restart: :transient
    require Logger

    def start_link(_opts), do: Task.start_link(__MODULE__, :run, [])

    def run do
      MayonnaiOS.Cores.clear_stale_directory()
      # Unconditional, every boot, and that is what makes these two settings
      # retractable rather than permanent. See clear_persisted_audio_sync/1 and
      # clear_persisted_autosave/1.
      MayonnaiOS.Cores.clear_persisted_audio_sync()
      MayonnaiOS.Cores.clear_persisted_autosave()
      MayonnaiOS.Cores.write_append_config()
      MayonnaiOS.Cores.sync()
    rescue
      e -> Logger.warning("[cores] could not sync: #{Exception.message(e)}")
    end
  end
end
