defmodule ScenicRg40xxv.Cores do
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

  So the flat directory `/root/retroarch/cores` is the one RetroArch is told
  about, it is outside every bundle, and it holds symlinks. `sync/0` rebuilds
  it from the two places cores actually come from:

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

  Cores are therefore built by `retroarch-rg40xxv` against the same sysroot as
  everything else and published as their own small tarballs, and installed
  here by the mechanism already proven for RetroArch itself: fetch, verify the
  SHA-256 *before* unpacking, install to a versioned directory, move a
  symlink. `ScenicRg40xxv.Bundle` does all of that; this module only decides
  where and what.

  The catalogue lives in config, with the firmware, for the same reason the
  RetroArch spec does: a checksum served from beside the file it describes is
  not evidence of anything.
  """

  require Logger

  alias ScenicRg40xxv.Bundle

  @doc """
  Where core bundles are installed, one versioned directory per core.
  """
  def root, do: Application.get_env(:scenic_rg40xxv, :core_root, "/root/cores")

  @doc """
  The flat directory RetroArch's `libretro_directory` points at.
  """
  def dir, do: Application.get_env(:scenic_rg40xxv, :core_dir, "/root/retroarch/cores")

  @doc """
  The core catalogue, keyed by core name.
  """
  def catalogue, do: Application.get_env(:scenic_rg40xxv, :cores, %{})

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
    Relinks the core directory once at boot.

    Cheap -- a listing and a handful of symlinks -- and it is the step that
    makes a RetroArch upgrade not lose the installed cores: `current` has
    moved by the time this runs, so the links follow it.

    `:transient`, and a failure here must not take the boot down. A device
    with no cores still boots to a menu and still has SSH; one that refuses to
    start has neither.
    """

    use Task, restart: :transient
    require Logger

    def start_link(_opts), do: Task.start_link(__MODULE__, :run, [])

    def run do
      ScenicRg40xxv.Cores.sync()
    rescue
      e -> Logger.warning("[cores] could not sync: #{Exception.message(e)}")
    end
  end
end
