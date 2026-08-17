defmodule MayonnaiOS.Udev do
  @moduledoc """
  Starts `udevd` on demand, for programs that are not Elixir.

  Nothing in a Nerves system needs this. Device nodes come from devtmpfs and
  `nerves_uevent` handles uevents in Elixir, so the daemon would be redundant
  for anything in this application. It exists for third-party Linux userland
  that has no other way to find an input device.

  RetroArch is the case that forced it. Without udev it renders perfectly on
  this board and then exits before drawing a frame:

      [Video] Graphics driver did not initialize an input driver.
      [ERROR] [Video] Cannot initialize input driver. Exiting...

  On Linux, udev *is* RetroArch's evdev path. Its other input drivers are
  `linuxraw`, which reads console keycodes and so cannot see gamepad `BTN_*`
  events, and `sdl`, which needs SDL. There is no plain evdev driver, and this
  kernel has no `joydev`, so `/dev/input/js*` does not exist either.

  ## Why a trigger is needed and not just the daemon

  `udev_input.c` picks devices with

      udev_enumerate_add_match_property(enumerate, "ID_INPUT_KEY", "1")

  and those properties are not read from the device -- they are *computed* by
  udev's `input_id` builtin when a rule runs, and stored in the udev database.
  Starting `udevd` after boot does nothing for devices that already exist,
  because their `add` uevents were emitted long before, while nothing was
  listening. `udevadm trigger` re-emits them so the rules run and the database
  fills in. Without it, `udevd` is running, the database is empty, RetroArch
  enumerates nothing, and it fails exactly as it did with no udev at all --
  which would look like the fix not working.

  ## Why on demand rather than at boot

  The boot path already carries one fragile thing: erlinit's `--pre-run-exec`
  loads the panel module, and without it there is no display at all. Adding a
  daemon start there risks the one sequence that must not break, for the
  benefit of a program that may never be launched. Starting it the first time
  something needs it costs a few hundred milliseconds and keeps boot alone.
  """

  require Logger

  # Searched rather than hardcoded. eudev puts udevd in /sbin and udevadm in
  # /usr/bin on this image, which is not the pairing you would guess, and /bin
  # is a real directory here rather than a symlink to /usr/bin -- so a single
  # wrong guess fails at the trigger step, after the daemon has already
  # started, and looks like the trigger not working.
  @udevd_paths ["/sbin/udevd", "/usr/sbin/udevd", "/lib/systemd/systemd-udevd"]
  @udevadm_paths ["/usr/bin/udevadm", "/bin/udevadm", "/sbin/udevadm"]

  @doc """
  Ensure `udevd` is running and the input devices are in its database.

  Idempotent and safe to call before every launch. Returns `:ok`, or
  `{:error, reason}` if the tools are missing -- which on this system means
  the running firmware predates eudev.
  """
  def ensure_started do
    cond do
      not File.exists?(udevd()) ->
        {:error, {:missing, udevd()}}

      running?() ->
        :ok

      true ->
        start()
    end
  end

  @doc """
  Whether a udev daemon is already running.

  Checked by asking the daemon rather than by looking for a process: udevadm
  talks to it over its control socket, so a stale pid or a daemon that has
  wedged reports as not running, which is the answer that leads somewhere.
  """
  def running? do
    case cmd(udevadm(), ["control", "--ping"]) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp start do
    Logger.info("[udev] starting #{udevd()}")

    case cmd(udevd(), ["--daemon"]) do
      {_, 0} -> settle_after_trigger()
      {out, rc} -> {:error, {:udevd, rc, String.trim(out)}}
    end
  end

  # Replay the uevents for devices that already existed, then wait for the
  # rules to finish. Only the input subsystem: everything else on this board
  # is already handled by nerves_uevent, and re-triggering it would be noise
  # at best.
  defp settle_after_trigger do
    case cmd(udevadm(), ["trigger", "--action=add", "--subsystem-match=input"]) do
      {_, 0} ->
        # Bounded, because a wedged settle must not hang a button press.
        cmd(udevadm(), ["settle", "--timeout=5"])
        :ok

      {out, rc} ->
        {:error, {:trigger, rc, String.trim(out)}}
    end
  end

  defp udevd, do: Application.get_env(:mayonnaios, :udevd_path) || find(@udevd_paths)
  defp udevadm, do: Application.get_env(:mayonnaios, :udevadm_path) || find(@udevadm_paths)

  # The first candidate is returned when none exist, so the error names a
  # plausible path instead of nil.
  defp find(candidates), do: Enum.find(candidates, &File.exists?/1) || hd(candidates)

  defp cmd(exe, args) do
    System.cmd(exe, args, stderr_to_stdout: true)
  rescue
    e -> {Exception.message(e), :error}
  end
end
