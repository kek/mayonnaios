defmodule MayonnaiOS.Saves do
  @moduledoc """
  Pushes RetroArch's save files onto the card at the one moment this
  application is allowed to: after the program that owns them has exited.

  ## What this is for, and what it is not

  `MayonnaiOS.Cores.write_append_config/0` makes RetroArch write the SRAM
  `.srm` every ten seconds instead of only on a clean close. That fixes *when
  the bytes are handed to the kernel*. It does not make them durable.

  RetroArch's autosave writes through libretro-common's `filestream`, which
  flushes to the kernel and does not fsync. The bytes then sit in the page
  cache until f2fs writes them back on its own schedule -- and this device is
  switched off by pulling its power, has no clean shutdown in normal use, and
  has no `sync` binary, not even a busybox applet. A write that is not fsynced
  is a write that survives exactly as long as the page cache. That has already
  cost a set of ROMs once, which is why `MayonnaiOS.Files` fsyncs every copy it
  makes.

  The application cannot fsync RetroArch's handle -- it is RetroArch's, in
  another process, and there is no syscall to reach it. What it can do is open
  those files itself, once, and fsync them. On Linux `fsync(2)` takes any
  descriptor for the file and flushes the *inode's* dirty pages, whoever
  dirtied them, so a read-only handle opened after the writer is gone is
  enough. That is the whole mechanism.

  ## Why "after the program has exited" is load-bearing rather than convenient

  Doing this while RetroArch runs would be worse than not doing it. An
  autosave is a truncate followed by one 8 KB write; fsyncing in the middle of
  that pair would make the truncation durable and the contents not, which is a
  way of turning "a save from ten seconds ago" into "no save at all". The
  window is microseconds wide and this would be a real bug in exchange for
  nothing, because the next autosave rewrites the file anyway.

  So there is no timer here. `MayonnaiOS.Launcher` calls `flush/1` at the two
  moments it knows the program is gone rather than merely finished with: when
  the port reports the exit, and when a stop has escalated as far as SIGKILL
  and *confirmed* the process died. A stop that could not confirm it does not
  flush -- that program still has the display and could still write a save, and
  the launcher reports it as still running for the same reason. Two further
  consequences worth stating:

    * A power cable pulled *during* a game is not covered by this module at
      all. What covers that is the autosave interval plus whatever f2fs has
      already written back, and nothing in this firmware can do better without
      an fsync it is not allowed to make.
    * A flush runs after kmscube too. Nothing here models which programs write
      saves, and an fsync of a file with no dirty pages is close to free, so
      the launcher is not given a list to get wrong.

  ## What is honestly not guaranteed

  The *directory entry* is not fsynced: OTP cannot open a directory, so
  `File.open/2` on one fails and there is no handle to sync. For a save file
  that already existed this does not matter -- the name is old and only the
  data is new. For a game's very first save the entry itself is new, and on
  f2fs `fsync` of a newly created inode forces a checkpoint that persists the
  parent directory with it. That last sentence is read from f2fs's behaviour
  in `posix` fsync mode, not measured on this card, and it is the one claim
  here that a power-pull test could falsify.

  Nothing in this module is verified against a real power cut. What is
  verified is that it opens the right directory, fsyncs every file in it, and
  survives a directory that does not exist yet -- which is the state of a
  device where nobody has saved anything.

  ## Why savestates are not touched

  `savestate_directory` holds megabyte-sized files written only when the
  player explicitly asks, and no save state has yet been lost on this device.
  Adding it would put multi-megabyte fsyncs on the path back from a game to
  the menu for a failure nobody has had. If that changes, the directory
  resolution below is the part to reuse.
  """

  require Logger

  alias MayonnaiOS.{Bundle, Cores}

  # A ceiling on the work one flush can do, most recently modified first.
  #
  # There is no bound on how many save files a card can accumulate, and this
  # runs on the way back to the menu, where a long stall reads as the launcher
  # having hung. Sorting by mtime is what makes a cap safe rather than
  # arbitrary: a file that could still be dirty is a file that was written
  # recently, and the ones past the cap were written in some earlier session
  # and have long since been written back.
  @max_files 64

  @doc """
  The directory RetroArch writes SRAM into.

  Resolved rather than assumed, because getting it wrong would be invisible:
  fsyncing an empty directory succeeds, logs a cheerful zero and protects
  nothing. The order below is RetroArch's own precedence -- the main config is
  read first and each `--appendconfig` file is merged over it, so the last
  file to set the value wins.

  A value of `"default"` or `""` is RetroArch saying it has no opinion, and a
  value naming a directory that does not exist is one RetroArch itself would
  drop on load, so both fall through to the default: `saves` beside the main
  config, which is where `Snes9x 2010/Chrono Trigger (U) [!].srm` actually is
  on the device.
  """
  def dir do
    Application.get_env(:mayonnaios, :retroarch_save_dir) || configured_dir() || default_dir()
  end

  @doc """
  Where RetroArch puts saves when nothing configures it: `saves` next to its
  own config.
  """
  def default_dir, do: Path.join(Path.dirname(Cores.retroarch_config()), "saves")

  @doc """
  Fsync every save file, and answer with how many were synced.

  `{:ok, 0}` for a directory that is not there yet or holds nothing -- a
  device where no game has saved is not a device with a problem.

  A file that cannot be opened or synced is logged and skipped rather than
  aborting the rest: this runs on the way back to the menu, and one unreadable
  file must not cost the flush of the save that matters.

  Options are the test seams: `:dir` to point somewhere writable, and `:sync`
  to stand in for `:file.sync/1` -- there is no way to observe from Elixir
  whether an fsync reached the card, so what the tests check is that every
  file gets one.
  """
  def flush(opts \\ []) do
    dir = Keyword.get(opts, :dir, dir())
    sync = Keyword.get(opts, :sync, &:file.sync/1)

    case files(dir) do
      [] ->
        {:ok, 0}

      files ->
        synced = Enum.count(files, &(flush_file(&1, sync) == :ok))
        Logger.info("[saves] fsynced #{synced}/#{length(files)} file(s) in #{dir}")
        {:ok, synced}
    end
  end

  # Read-only and :raw. Read-only because this must not be able to change a
  # save file even by accident -- an fsync needs a descriptor, not write
  # access. :raw because there is nothing to read: the handle exists solely to
  # be synced, so there is no reason to put an IO server in front of it.
  defp flush_file(path, sync) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, handle} ->
        result = sync.(handle)
        File.close(handle)

        case result do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("[saves] could not fsync #{path}: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("[saves] could not open #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Every regular file below the save directory, newest first, capped.
  #
  # Recursive because `sort_savefiles_enable = "true"` puts each core's saves
  # in its own subdirectory, so the interesting file is one level down and a
  # flat listing would find nothing.
  defp files(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort_by(&mtime/1, :desc)
    |> Enum.take(@max_files)
  end

  # A file that cannot be stat'd sorts last rather than raising; it is still
  # attempted, and the open will report whatever is actually wrong with it.
  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      {:error, _} -> 0
    end
  end

  defp configured_dir do
    Enum.find_value(config_files(), &savefile_directory/1)
  end

  # Least specific first, so `find_value` has to look at them in reverse:
  # RetroArch merges each appended file over the main config, so the last one
  # to set the value is the one that decides it.
  defp config_files do
    [Cores.retroarch_config(), bundle_config(), Cores.append_config()]
    |> Enum.reject(&is_nil/1)
    |> Enum.reverse()
  end

  # The config inside the installed RetroArch bundle, which the launcher
  # appends on every launch. Named here from the same two facts the launch
  # arguments are built from; nil when no bundle is installed.
  defp bundle_config do
    case Bundle.current("retroarch") do
      nil -> nil
      current -> Path.join([current, "share", "retroarch", "retroarch.cfg"])
    end
  end

  defp savefile_directory(path) do
    with {:ok, contents} <- File.read(path),
         value when is_binary(value) <- setting(contents, "savefile_directory"),
         false <- value in ["", "default"],
         expanded = Path.expand(value),
         true <- File.dir?(expanded) do
      expanded
    else
      _ -> nil
    end
  end

  defp setting(contents, key) do
    contents
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^\s*#{Regex.escape(key)}\s*=\s*"?(.*?)"?\s*$/, line) do
        [_, value] -> value
        nil -> nil
      end
    end)
  end
end
