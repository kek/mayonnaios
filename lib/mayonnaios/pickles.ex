defmodule MayonnaiOS.Pickles do
  @moduledoc """
  Pickles: small sandboxed Lua apps, installed over the network like games.

  Everything else on this menu is a sandwich, so the little scripted extras
  are pickles. A pickle is a directory with a manifest and some Lua -- see
  `MayonnaiOS.Pickles.Store` for the disk shape, `MayonnaiOS.Pickles.Sandbox`
  for what the Lua is allowed to do, and `MayonnaiOS.Pickles.Runner` for the
  process one becomes when it runs. `docs/pickles.md` is the guide for
  writing one.

  This module is the front door: install, start, stop, call, and the
  supervision plumbing. The web API in `MayonnaiOS.Web` is a thin layer over
  exactly these functions, so the phone and the console see the same
  behaviour.

  ## Why in-VM Lua and not another OS process

  The launcher already runs external programs, but those take the display and
  the input with them. A pickle is the other kind of app: no screen of its
  own, long-lived, talking to lamps and web services in the background while
  a game runs. That wants to be cheap (a GenServer, not a unix process), to
  survive being buggy (one killed BEAM process, not a zombie holding evdev),
  and to be inspectable from the console. Luerl gives all three for the price
  of a pure-Erlang dependency.
  """

  require Logger

  alias MayonnaiOS.Pickles.{Runner, Sandbox, Store}

  @registry MayonnaiOS.Pickles.Registry
  @jar MayonnaiOS.Pickles.Jar

  @doc """
  Where pickles live. On the writable application partition, next to bundles.
  """
  def root, do: Application.get_env(:mayonnaios, :pickles_root, "/root/pickles")

  @doc """
  The supervision subtree: a registry of running pickles and the
  DynamicSupervisor they run under -- the jar the pickles are kept in.
  Empty on boot, on the host as well as the device, same arrangement as
  `MayonnaiOS.Controller.sessions/0`.
  """
  @spec sessions() :: Supervisor.child_spec()
  def sessions do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @jar, strategy: :one_for_one}
    ]

    %{
      id: __MODULE__.Sessions,
      start:
        {Supervisor, :start_link, [children, [name: __MODULE__.Sessions, strategy: :one_for_one]]},
      type: :supervisor
    }
  end

  @doc """
  Installed pickles with their run state, for the web page and the console.
  """
  def list do
    Enum.map(Store.list(root()), fn entry ->
      case Runner.whereis(entry.name) do
        nil -> Map.put(entry, :running, false)
        _pid -> Map.put(entry, :running, true)
      end
    end)
  end

  @doc """
  Install the `.tar.gz` at `tarball` as `name`.

  A running pickle is stopped for the swap and started again after, so the
  deploy loop is one PUT: upload, and the new code is what answers. A pickle
  that was not running is started if its manifest says `autostart` -- pushing
  a new autostart pickle should not additionally require knowing to start it.
  """
  def install(name, tarball) do
    was_running = Runner.whereis(name) != nil
    if was_running, do: Runner.stop(name)

    case Store.install(root(), name, tarball) do
      {:ok, manifest} ->
        if was_running or manifest.autostart, do: start(name)
        {:ok, manifest}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stop and remove `name`, including its remembered state.
  """
  def delete(name) do
    if Runner.whereis(name), do: Runner.stop(name)
    Store.delete(root(), name)
  end

  @doc """
  Start the installed pickle `name`.
  """
  def start(name) do
    case DynamicSupervisor.start_child(@jar, {Runner, name: name, root: root()}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, {reason, _child_spec}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Stop the running pickle `name`.
  """
  def stop(name), do: Runner.stop(name)

  @doc """
  Call the global Lua function `fname` in `name` with `args`.

      iex> MayonnaiOS.Pickles.call("tuya-lamps", "toggle", [])
      {:ok, [true]}
  """
  def call(name, fname, args \\ []), do: Runner.call(name, fname, args)

  @doc """
  Status and recent log of `name`, or `{:error, :not_running}`.
  """
  def info(name), do: Runner.info(name)

  defdelegate jsonable(term), to: Sandbox

  defmodule Startup do
    @moduledoc """
    Starts the pickles whose manifests say `autostart`, once, at boot.

    A Task rather than logic in the supervisor: a pickle that fails to start
    is a log line and an `:error` status, never a boot that fails. Broken
    entries (unreadable manifests) are skipped here and still shown by
    `list/0`, which is where a person will look.
    """
    use Task, restart: :transient

    def start_link(_opts) do
      Task.start_link(__MODULE__, :run, [])
    end

    def run do
      for %{autostart: true, name: name} <- MayonnaiOS.Pickles.list() do
        case MayonnaiOS.Pickles.start(name) do
          {:ok, _pid} -> :ok
          {:error, reason} -> Logger.warning("[pickles] autostart #{name}: #{inspect(reason)}")
        end
      end
    end
  end
end
