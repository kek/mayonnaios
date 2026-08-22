defmodule MayonnaiOS.AppPartition do
  @moduledoc """
  Stops f2fs issuing discards to the card that holds `/root`.

  ## Why

  On 2026-08-22 the device stopped being able to do anything filesystem-shaped
  while still evaluating Elixir perfectly well over SSH. The state, read out of
  the running node without touching the filesystem: one process parked in
  `:prim_file.read_file_nif/1`, blocked inside the kernel on a read that never
  returned, and every subsequent file operation taking another of the ten dirty
  IO schedulers until there were none left. Reads worked for the first forty
  minutes of the session and then did not.

  The kernel log had one line to offer, and it repeats about a minute into
  every boot:

      mmc_erase: group start error -110, status 0x0

  `-110` is `-ETIMEDOUT`, and `mmc_erase` is a discard. `/proc/mounts` says
  where the discards come from:

      /dev/mmcblk0p4 /root f2fs rw,...,discard,discard_unit=block,...
      /dev/mmcblk2p1 /root/mnt/games exfat rw,nosuid,nodev,noexec,...

  So it is the *OS* card's application partition, not the games card, which was
  the first guess and was wrong -- exFAT issues no discards at all. And nothing
  in this project asked for `discard`: the system's `erlinit.config` mounts with

      -m /dev/mmcblk0p4:/root:f2fs:nodev:

  and `discard` is simply what f2fs defaults to when the device claims to
  support it. This card times out on erase instead.

  ## Why a remount and not the sysfs knob

  `/sys/fs/f2fs/mmcblk0p4/max_small_discards` can be set to 0 at runtime, and
  that was the first stopgap. But it is a bound on one *class* of discard, so
  it does not say the thing we want said. `nodiscard` does, and f2fs accepts it
  on remount -- verified on the device before this module was written:
  `mount -o remount,nodiscard /root` returned 0 and `/proc/mounts` then read
  `nodiscard`.

  The right place for this is the system's `erlinit.config`, one word longer:
  `nodev,nodiscard`. That file lives in the system repo's `rootfs_overlay/`,
  which is in `package_files()`, so changing it changes the artifact checksum
  and costs a full Buildroot rebuild. Until someone is rebuilding anyway, this
  module does it from the application, where it ships in minutes.

  ## What it checks

  A zero exit status from `mount` is not evidence. This project has been caught
  three times by reading a file, or a return value, and calling it the state of
  the program -- so `disable_discard/1` re-reads `/proc/mounts` afterwards and
  reports failure if the mount is still discarding, whatever `mount` said.

  ## What is not established

  That the discard timeouts are what wedged the device. The mechanism fits and
  the correlation is strong, but the process actually caught blocking was doing
  a read, not a discard, and by then the filesystem needed to investigate any
  further was the thing that had stopped working. If the device wedges again
  with `nodiscard` in `/proc/mounts`, this was the wrong cause and the fix
  should come back out rather than stay as decoration.
  """

  require Logger

  @mount_point "/root"

  @doc """
  The mount point to take out of discard mode.
  """
  def mount_point do
    Application.get_env(:mayonnaios, :app_partition_mount_point, @mount_point)
  end

  @doc """
  Remount the application partition with `nodiscard`, and confirm it took.

  Returns `:ok`, or `{:error, reason}`. Never raises: a device that cannot do
  this still boots, still has a menu and still has SSH, and the log line is
  what someone needs in order to find out why the discards came back.

  Options exist for tests: `:mount_point`, `:proc_mounts` (path to read back)
  and `:run` (a `System.cmd/3`-shaped function).
  """
  def disable_discard(opts \\ []) do
    mount_point = Keyword.get(opts, :mount_point, mount_point())
    proc_mounts = Keyword.get(opts, :proc_mounts, "/proc/mounts")
    run = Keyword.get(opts, :run, &System.cmd/3)

    with :ok <- remount(run, mount_point),
         :ok <- confirm(proc_mounts, mount_point) do
      Logger.info("[partition] #{mount_point} remounted nodiscard")
      :ok
    else
      {:error, reason} = error ->
        Logger.warning("[partition] #{mount_point} still discarding: #{inspect(reason)}")
        error
    end
  end

  defp remount(run, mount_point) do
    case run.("mount", ["-o", "remount,nodiscard", mount_point], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {:mount_failed, code, String.trim(out)}}
    end
  rescue
    # No mount binary, or no permission to run it. Both are reasons this cannot
    # work rather than reasons to stop booting.
    e -> {:error, {:mount_unavailable, Exception.message(e)}}
  end

  # `mount` exiting 0 is not the claim being made. The claim is that this mount
  # is no longer discarding, and /proc/mounts is where that is written down.
  defp confirm(proc_mounts, mount_point) do
    with {:ok, contents} <- File.read(proc_mounts),
         {:ok, options} <- find_mount(contents, mount_point) do
      if "nodiscard" in options do
        :ok
      else
        {:error, {:still_discarding, options |> Enum.filter(&(&1 =~ "discard"))}}
      end
    end
  end

  defp find_mount(contents, mount_point) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.map(&String.split(&1, " "))
    |> Enum.find_value({:error, {:not_mounted, mount_point}}, fn
      [_dev, ^mount_point, _type, options | _rest] -> {:ok, String.split(options, ",")}
      _ -> false
    end)
  end

  defmodule Startup do
    @moduledoc """
    Runs `MayonnaiOS.AppPartition.disable_discard/1` once at boot.

    Early, because the discards it is stopping are issued by writes to `/root`
    and everything else in the boot sequence writes to `/root`. Not so early
    that it displaces the three children ahead of it, which are there to make a
    failing boot diagnosable.

    `:transient`, and for the same reason as `MayonnaiOS.Cores.Startup`: a
    device that cannot remount its own application partition should still come
    up to a menu with SSH on it, so someone can find out why.
    """

    use Task, restart: :transient

    def start_link(_opts), do: Task.start_link(__MODULE__, :run, [])

    def run, do: MayonnaiOS.AppPartition.disable_discard()
  end
end
