defmodule MayonnaiOS.HostRuntime do
  @moduledoc """
  Prepares and starts the complete host development runtime.

  The host uses the real Launcher, Scenic scenes, Elixir apps and Luerl pickle
  runner. Only the hardware edges are substituted: keyboard events become the
  gamepad's evdev reports, one short shell command stands in for an external
  KMS program, and writable state lives in ignored development directories.
  """

  use GenServer

  @doc false
  def children do
    [__MODULE__, MayonnaiOS.Web, MayonnaiOS.Launcher, MayonnaiOS.Keyboard]
  end

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(opts) do
    paths = %{
      files: Keyword.get(opts, :files, host_file_root()),
      backlight: Keyword.get(opts, :backlight, MayonnaiOS.Sleep.path()),
      pickles: Keyword.get(opts, :pickles, MayonnaiOS.Pickles.root()),
      example: Keyword.get(opts, :example, Path.expand("pickles/hello"))
    }

    case prepare(paths) do
      :ok -> {:ok, paths}
      {:error, reason} -> {:stop, reason}
    end
  end

  @doc false
  def prepare(paths) do
    with :ok <- File.mkdir_p(paths.files),
         :ok <- seed_file(Path.join(paths.files, "README.txt"), host_readme()),
         :ok <- File.mkdir_p(Path.dirname(paths.backlight)),
         :ok <- seed_file(paths.backlight, "1"),
         :ok <- File.mkdir_p(paths.pickles),
         :ok <- seed_pickle(paths.example, Path.join(paths.pickles, "hello")) do
      :ok
    end
  end

  defp host_file_root do
    case Application.get_env(:mayonnaios, :file_roots, []) do
      [%{path: path} | _] -> path
      _ -> Path.expand("tmp/host/files")
    end
  end

  defp seed_file(path, contents) do
    if File.exists?(path), do: :ok, else: File.write(path, contents)
  end

  defp seed_pickle(source, destination) do
    if File.dir?(destination) do
      :ok
    else
      case File.cp_r(source, destination) do
        {:ok, _paths} -> :ok
        {:error, reason, _path} -> {:error, reason}
      end
    end
  end

  defp host_readme do
    "This directory is MayonnaiOS host-development scratch space.\n" <>
      "Use the Files column to exercise copy, move, rename and delete safely.\n"
  end
end
