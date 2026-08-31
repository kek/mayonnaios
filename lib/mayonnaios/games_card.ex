defmodule MayonnaiOS.GamesCard do
  @moduledoc """
  Mounts the card in the second SD slot, where the games live.

  The RG40XXV has two card slots. The first holds the OS and is `mmcblk0`; the
  second enumerates as **`mmcblk2`**, not `mmcblk1` -- `mmcblk1` is the SDIO
  WiFi. So the games partition is `/dev/mmcblk2p1`, and guessing the obvious
  name gets you the radio.

  The card is formatted the way a handheld's card is: one big exFAT partition
  written by a Mac or by the stock OS. Both `exfat` and `vfat` are built into
  the kernel and both are plausible in that slot, so this tries each in turn
  rather than assuming.

  ## Failure is normal here

  There may be no card. There may be a card with no filesystem this kernel
  understands. It may already be mounted from a previous attempt. None of those
  are reasons to fail a boot -- the device is a working console without the
  card, it just has fewer games -- so every one of them logs and returns `:ok`.

  ## Read-write, and what that costs

  Mounted `rw` so games can be added and deleted in place, which is the point
  of a games card. Two consequences worth knowing:

    * FAT and exFAT have no journal. This device is switched off by pulling
      power, and a write in flight at that moment can leave a directory entry
      half-written. The kernel's exFAT driver mounts `errors=remount-ro`, so
      the failure mode is the card going read-only rather than progressively
      eating itself, but a backup of anything irreplaceable belongs elsewhere.
      Setting `sync: true` in the config trades write speed for durability.

    * `nosuid,nodev,noexec` still apply. This is removable media that has been
      in other machines; FAT carries no ownership or permissions of its own, so
      a file appearing to be executable means nothing. Anything on the card
      that needs running should be copied off first.
  """

  use GenServer
  require Logger

  @defaults [
    mount_point: "/root/mnt/games",
    filesystems: ["exfat", "vfat"],
    options: "rw,nosuid,nodev,noexec",
    sync: false
  ]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Where the card is mounted, whether or not anything is there."
  def mount_point, do: config()[:mount_point]

  @doc "Whether the card is mounted right now, read from /proc/mounts."
  def mounted?, do: mounted?(config()[:mount_point])

  @doc """
  Mount the card, or report why not.

  Safe to call when it is already mounted; returns `{:ok, :already_mounted}`.
  """
  def mount, do: GenServer.call(__MODULE__, :mount, 15_000)

  @doc """
  Unmount the card, for pulling it out without corrupting it.

  On a read-write FAT mount this is the difference between a clean card and a
  card with a half-written directory, so it is worth doing before ejecting.
  """
  def unmount, do: GenServer.call(__MODULE__, :unmount, 15_000)

  @doc "Acquire the single monitored backup lease for `owner`."
  def acquire(owner) when is_pid(owner), do: GenServer.call(__MODULE__, {:acquire, owner})

  @doc "Release `owner`'s backup lease."
  def release(owner) when is_pid(owner), do: GenServer.call(__MODULE__, {:release, owner})

  @impl GenServer
  def init(opts) do
    cfg = Keyword.merge(config(), opts)
    {:ok, %{config: cfg, lease: nil}, {:continue, :mount}}
  end

  @impl GenServer
  def handle_continue(:mount, state) do
    _ = do_mount(state.config)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:mount, _from, state), do: {:reply, do_mount(state.config), state}

  def handle_call(:unmount, _from, %{lease: {_owner, _monitor}} = state),
    do: {:reply, {:error, :busy}, state}

  def handle_call(:unmount, _from, state), do: {:reply, do_unmount(state.config), state}

  def handle_call({:acquire, owner}, _from, %{lease: nil} = state) do
    {:reply, :ok, %{state | lease: {owner, Process.monitor(owner)}}}
  end

  def handle_call({:acquire, owner}, _from, %{lease: {owner, _monitor}} = state),
    do: {:reply, :ok, state}

  def handle_call({:acquire, _owner}, _from, state), do: {:reply, {:error, :busy}, state}

  def handle_call({:release, owner}, _from, %{lease: {owner, monitor}} = state) do
    Process.demonitor(monitor, [:flush])
    {:reply, :ok, %{state | lease: nil}}
  end

  def handle_call({:release, _owner}, _from, state), do: {:reply, :ok, state}

  @impl GenServer
  def handle_info({:DOWN, monitor, :process, owner, _reason}, %{lease: {owner, monitor}} = state),
    do: {:noreply, %{state | lease: nil}}

  def handle_info(_message, state), do: {:noreply, state}

  defp do_mount(cfg) do
    point = cfg[:mount_point]
    device = cfg[:device]

    cond do
      mounted?(point) ->
        Logger.info("[games] already mounted at #{point}")
        {:ok, :already_mounted}

      not File.exists?(device) ->
        # No card, or a card with no partition table. Expected, not a fault.
        Logger.info("[games] no card in the second slot (#{device} absent)")
        {:error, :no_card}

      true ->
        File.mkdir_p!(point)
        try_filesystems(cfg, device, point)
    end
  end

  # Each filesystem in turn, because the card's format is not knowable in
  # advance. The last error is the one reported: if exfat fails and vfat fails,
  # what matters is that neither worked, and both messages are logged.
  defp try_filesystems(cfg, device, point) do
    result =
      Enum.reduce_while(cfg[:filesystems], {:error, :no_filesystem}, fn fs, _acc ->
        case run_mount(fs, options(cfg), device, point) do
          :ok ->
            Logger.info("[games] mounted #{device} at #{point} as #{fs}")
            {:halt, {:ok, fs}}

          {:error, reason} ->
            Logger.debug("[games] #{fs} did not mount #{device}: #{reason}")
            {:cont, {:error, reason}}
        end
      end)

    case result do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        Logger.warning("[games] could not mount #{device}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp run_mount(fs, opts, device, point) do
    case System.cmd("/bin/mount", ["-t", fs, "-o", opts, device, point], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, code} -> {:error, "exit #{code}: #{String.trim(out)}"}
    end
  end

  defp do_unmount(cfg) do
    point = cfg[:mount_point]

    if mounted?(point) do
      case System.cmd("/bin/umount", [point], stderr_to_stdout: true) do
        {_, 0} ->
          Logger.info("[games] unmounted #{point}")
          :ok

        {out, code} ->
          # Usually something has a file open on the card -- a running emulator
          # holding a ROM is the obvious one.
          Logger.warning("[games] could not unmount #{point}: exit #{code} #{String.trim(out)}")
          {:error, String.trim(out)}
      end
    else
      {:ok, :not_mounted}
    end
  end

  defp options(cfg) do
    if cfg[:sync], do: cfg[:options] <> ",sync", else: cfg[:options]
  end

  # /proc/mounts rather than a flag in state: the mount can be changed from a
  # console, and state that disagrees with the kernel is worse than no state.
  defp mounted?(point) do
    case File.read("/proc/mounts") do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> Enum.any?(fn line ->
          case String.split(line, " ") do
            [_dev, ^point | _] -> true
            _ -> false
          end
        end)

      _ ->
        false
    end
  end

  defp config do
    [device: MayonnaiOS.Device.current!().games_card_device]
    |> Keyword.merge(@defaults)
    |> Keyword.merge(Application.get_env(:mayonnaios, :games_card, []))
  end
end
