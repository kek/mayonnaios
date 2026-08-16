defmodule ScenicRg40xxv.Library do
  @moduledoc """
  The game library on the writable partition: what systems exist, what is in
  them, and how a file gets in.

  Content lives at `/root/roms/<system>/<file>`, which is the layout RetroArch
  expects to be pointed at and the one the second SD card will mirror when its
  slot is enabled.

  ## Why every write goes through here

  The upload endpoint takes a filename from an HTTP request, and a filename
  from an HTTP request is the oldest way there is to write to somewhere you
  were not invited. `/root` is the only writable filesystem on this device and
  it holds the bundles, the saves and the application's own state, so a
  traversal out of the ROM directory is not a cosmetic bug -- `../../bundles/
  retroarch/current/bin/retroarch` is a real path here and it is executable.

  So `safe_name/1` is not a convenience: it is the boundary. It rejects rather
  than sanitises, because sanitising invites the question of whether the
  cleaning was complete, and rejecting does not:

    * anything containing `/` or a null byte
    * `.` and `..` exactly
    * anything starting with `.`, so nothing can land as a dotfile
    * anything whose extension the system does not claim

  `Path.basename/1` alone would not do. It maps `"../../x"` to `"x"`, which is
  safe but silently accepts a request that was trying to escape -- and a
  rejection that logs is worth more than a repair that does not.

  ## Systems

  Configured, not inferred:

      config :scenic_rg40xxv, :systems, [
        %{key: "snes", name: "Super Nintendo", extensions: [".sfc", ".smc", ".zip"]}
      ]

  A fixed list is what makes the directory component safe: `system` from a
  request is never used as a path, it is used to *look up* a system, and the
  path comes from the configured record. There is no sanitising to get wrong.
  """

  require Logger

  @type system :: %{key: String.t(), name: String.t(), extensions: [String.t()]}

  @doc """
  Where content is kept. Configurable so tests do not touch a real partition.
  """
  def root, do: Application.get_env(:scenic_rg40xxv, :rom_root, "/root/roms")

  @doc """
  The largest upload accepted, in bytes.

  There is 13 GB free, so this is not about space. It is about a request that
  never ends: without a ceiling, one client can fill the partition that holds
  the bundles and the saves, and the failure appears everywhere except where
  it was caused.
  """
  def max_bytes, do: Application.get_env(:scenic_rg40xxv, :max_upload_bytes, 1_073_741_824)

  @doc """
  The configured systems.
  """
  @spec systems() :: [system()]
  def systems, do: Application.get_env(:scenic_rg40xxv, :systems, [])

  @doc """
  Look a system up by key. `nil` if it is not one we know about.
  """
  @spec system(String.t()) :: system() | nil
  def system(key), do: Enum.find(systems(), &(&1.key == key))

  @doc """
  Every system with its contents, for the UI.
  """
  def index do
    Enum.map(systems(), fn sys -> Map.put(sys, :entries, entries(sys)) end)
  end

  @doc """
  What is in a system's directory, newest-looking name order, with sizes.
  """
  @spec entries(system() | String.t()) :: [%{name: String.t(), size: non_neg_integer()}]
  def entries(key) when is_binary(key) do
    case system(key) do
      nil -> []
      sys -> entries(sys)
    end
  end

  def entries(sys) do
    dir = dir(sys)

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.sort()
        |> Enum.flat_map(fn name ->
          case File.stat(Path.join(dir, name)) do
            {:ok, %{type: :regular, size: size}} -> [%{name: name, size: size}]
            _ -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  The directory for a system.
  """
  def dir(%{key: key}), do: Path.join(root(), key)

  @doc """
  The absolute path a name would take inside a system, or an error.

  The only function that turns request data into a path. Everything that
  writes or deletes goes through it.
  """
  @spec path(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :unknown_system | :bad_name | :bad_extension}
  def path(system_key, name) do
    with {:ok, sys} <- fetch_system(system_key),
         {:ok, name} <- safe_name(name),
         :ok <- check_extension(sys, name) do
      {:ok, Path.join(dir(sys), name)}
    end
  end

  @doc """
  Whether a filename may be used at all.

  Rejects; does not repair. See the moduledoc for why.
  """
  @spec safe_name(String.t()) :: {:ok, String.t()} | {:error, :bad_name}
  def safe_name(name) when is_binary(name) do
    cond do
      name in ["", ".", ".."] -> {:error, :bad_name}
      String.contains?(name, ["/", "\\", <<0>>]) -> {:error, :bad_name}
      String.starts_with?(name, ".") -> {:error, :bad_name}
      String.length(name) > 200 -> {:error, :bad_name}
      not String.valid?(name) -> {:error, :bad_name}
      true -> {:ok, name}
    end
  end

  def safe_name(_), do: {:error, :bad_name}

  @doc """
  Stream a request body into a system's directory.

  `read_chunk` is called repeatedly and must return `{:ok, binary, next}`,
  `{:more, binary, next}` or `{:error, reason}` -- the shape `Plug.Conn.
  read_body/2` already has, so the web layer passes its own conn through
  without an adapter.

  Written to a `.part` file beside the destination and renamed at the end.
  Same directory, so the rename is atomic rather than a copy: a connection
  that drops halfway leaves a `.part` that the listing hides, never a
  truncated ROM that looks like a real one and fails at the checksum screen
  of a game three hours later.
  """
  @spec receive_upload(String.t(), String.t(), term(), (term() -> tuple())) ::
          {:ok, %{name: String.t(), size: non_neg_integer(), path: String.t()}}
          | {:error, term()}
  def receive_upload(system_key, name, chunk_state, read_chunk) do
    with {:ok, dest} <- path(system_key, name) do
      File.mkdir_p!(Path.dirname(dest))
      part = dest <> ".part"
      File.rm(part)

      case File.open(part, [:write, :binary, :raw]) do
        {:ok, fd} ->
          result = pump(fd, chunk_state, read_chunk, 0)
          # fsync before close, not after: this partition is f2fs and the
          # device is a handheld that gets switched off by holding a button.
          # An unsynced 200 MB write survives exactly as long as the page
          # cache does, which was measured here at less than one reboot.
          :file.sync(fd)
          File.close(fd)
          finish(result, part, dest, name)

        {:error, reason} ->
          {:error, {:open, reason}}
      end
    end
  end

  defp pump(fd, state, read_chunk, written) do
    case read_chunk.(state) do
      {:ok, data, _next} ->
        total = written + byte_size(data)

        if total > max_bytes() do
          {:error, :too_large}
        else
          # :file.write and not IO.binwrite -- the fd is opened :raw, which
          # skips the IO server, and the IO functions do not speak to it.
          case :file.write(fd, data) do
            :ok -> {:ok, total}
            {:error, reason} -> {:error, {:write, reason}}
          end
        end

      {:more, data, next} ->
        total = written + byte_size(data)

        if total > max_bytes() do
          # Stop reading. The socket is closed by the caller's error response,
          # which is the only way to make a client stop sending: there is no
          # polite way to decline the second half of a body.
          {:error, :too_large}
        else
          case :file.write(fd, data) do
            :ok -> pump(fd, next, read_chunk, total)
            {:error, reason} -> {:error, {:write, reason}}
          end
        end

      {:error, reason} ->
        {:error, {:read, reason}}
    end
  end

  defp finish({:ok, size}, part, dest, name) do
    case File.rename(part, dest) do
      :ok ->
        Logger.info("[library] stored #{name} (#{size} bytes)")
        {:ok, %{name: name, size: size, path: dest}}

      {:error, reason} ->
        File.rm(part)
        {:error, {:rename, reason}}
    end
  end

  defp finish({:error, reason}, part, _dest, name) do
    File.rm(part)
    Logger.warning("[library] rejected #{name}: #{inspect(reason)}")
    {:error, reason}
  end

  @doc """
  Delete one entry.
  """
  @spec delete(String.t(), String.t()) :: :ok | {:error, term()}
  def delete(system_key, name) do
    with {:ok, dest} <- path(system_key, name) do
      case File.rm(dest) do
        :ok ->
          Logger.info("[library] deleted #{name}")
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Free bytes on the partition holding the library.

  Read from `df`, because there is no statvfs in OTP and busybox's df is in
  the image. Returns `nil` rather than guessing if the output does not parse.
  """
  def free_bytes do
    {out, 0} = System.cmd("df", ["-k", root()], stderr_to_stdout: true)

    out
    |> String.split("\n", trim: true)
    |> List.last()
    |> String.split()
    |> Enum.at(3)
    |> String.to_integer()
    |> Kernel.*(1024)
  rescue
    _ -> nil
  end

  defp fetch_system(key) do
    case system(key) do
      nil -> {:error, :unknown_system}
      sys -> {:ok, sys}
    end
  end

  defp check_extension(sys, name) do
    ext = name |> Path.extname() |> String.downcase()
    if ext in sys.extensions, do: :ok, else: {:error, :bad_extension}
  end
end
