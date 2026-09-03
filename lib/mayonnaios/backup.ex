defmodule MayonnaiOS.Backup do
  @moduledoc """
  Creates one verified, portable backup of the configured user-data catalog.

  Work is staged below `MayonnaiOS/backup-v1/.staging`; `manifest.json` is
  written last and is the validity marker. Publication rotates `current`
  through `.previous`, retaining a recoverable old copy until the new copy
  validates. Source paths come only from configuration, never from UI input.
  """

  @version 1
  @chunk 65_536
  @layout "MayonnaiOS/backup-v1"
  @allowance 65_536

  @type entry :: %{
          root: String.t(),
          components: [String.t()],
          type: :directory | :regular,
          size: non_neg_integer(),
          mtime: term()
        }

  @doc "The fixed logical source catalog."
  def catalog do
    Application.get_env(:mayonnaios, :backup_sources, [])
    |> Enum.map(fn source ->
      source
      |> Map.new()
      |> Map.put_new(:exclude, [])
    end)
  end

  @doc "Preflight the configured catalog and destination without writing."
  def preflight(opts \\ []) do
    sources = Keyword.get(opts, :sources, catalog())
    destination = Keyword.get_lazy(opts, :destination, &destination/0)
    space = Keyword.get(opts, :space, &free_bytes/1)
    cancelled? = Keyword.get(opts, :cancelled?, fn -> false end)

    with :ok <- destination_ready(destination),
         {:ok, entries, absent} <- scan_sources(sources, cancelled?),
         bytes = entries |> Enum.filter(&(&1.type == :regular)) |> Enum.sum_by(& &1.size),
         files = Enum.count(entries, &(&1.type == :regular)),
         required = bytes + max(div(bytes * 5 + 99, 100), @allowance),
         {:ok, available} <- space.(destination),
         true <- available >= required || {:error, :insufficient_space} do
      {:ok,
       %{
         version: @version,
         destination: destination,
         sources: Enum.map(sources, &(Map.new(&1) |> Map.fetch!(:key) |> to_string())),
         absent: absent,
         entries: entries,
         files: files,
         bytes: bytes,
         required_bytes: required
       }}
    else
      {:error, _} = error -> error
      false -> {:error, :insufficient_space}
    end
  end

  @doc "Run a complete leased, staged, verified backup."
  def run(opts \\ []) do
    owner = self()
    acquire = Keyword.get(opts, :acquire, &MayonnaiOS.GamesCard.acquire/1)
    release = Keyword.get(opts, :release, &MayonnaiOS.GamesCard.release/1)

    with :ok <- acquire.(owner) do
      try do
        with {:ok, plan} <- preflight(opts),
             :ok <- recover(plan.destination),
             :ok <- create_staging(plan, opts),
             :ok <- publish(plan.destination) do
          {:ok, %{destination: current(plan.destination), files: plan.files, bytes: plan.bytes}}
        end
      after
        _ = release.(owner)
      end
    end
  end

  @doc "Validate a published or staged backup and every recorded checksum."
  def validate(path) do
    with {:ok, bytes} <- File.read(Path.join(path, "manifest.json")),
         {:ok, manifest} <- Jason.decode(bytes),
         true <- manifest["format_version"] == @version || {:error, :format_version},
         true <- manifest["complete"] == true || {:error, :incomplete},
         records when is_list(records) <- manifest["files"],
         :ok <- unique_safe_records(records),
         :ok <- verify_records(path, records) do
      :ok
    else
      {:error, _} = error -> error
      false -> {:error, :invalid_manifest}
      _ -> {:error, :invalid_manifest}
    end
  end

  defp scan_sources(sources, cancelled?) do
    Enum.reduce_while(sources, {:ok, [], []}, fn raw, {:ok, entries, absent} ->
      source = Map.new(raw)
      key = source |> Map.fetch!(:key) |> to_string()
      path = Map.fetch!(source, :path)
      excludes = Map.get(source, :exclude, []) |> Enum.map(&List.wrap/1)

      cond do
        cancelled?.() ->
          {:halt, {:error, :cancelled}}

        not File.exists?(path) ->
          {:cont, {:ok, entries, absent ++ [key]}}

        true ->
          case walk(path, key, [], excludes, cancelled?) do
            {:ok, found} -> {:cont, {:ok, entries ++ found, absent}}
            {:error, _} = error -> {:halt, error}
          end
      end
    end)
    |> case do
      {:ok, entries, absent} -> {:ok, Enum.sort_by(entries, &{&1.root, &1.components}), absent}
      error -> error
    end
  end

  defp walk(path, root, components, excludes, cancelled?) do
    cond do
      cancelled?.() ->
        {:error, :cancelled}

      excluded?(components, excludes) ->
        {:ok, []}

      true ->
        with :ok <- safe_components(components),
             {:ok, before} <- File.lstat(path) do
          case before.type do
            :directory ->
              with {:ok, names} <- File.ls(path),
                   {:ok, children} <-
                     walk_children(path, root, components, names, excludes, cancelled?),
                   {:ok, after_stat} <- File.lstat(path),
                   true <- same?(before, after_stat) || {:error, :source_changed} do
                entry = %{
                  root: root,
                  components: components,
                  type: :directory,
                  size: 0,
                  mtime: before.mtime
                }

                {:ok, [entry | children]}
              end

            :regular ->
              {:ok,
               [
                 %{
                   root: root,
                   components: components,
                   type: :regular,
                   size: before.size,
                   mtime: before.mtime
                 }
               ]}

            :symlink ->
              {:error, {:unsupported, :symlink, components}}

            type ->
              {:error, {:unsupported, type, components}}
          end
        end
    end
  end

  defp walk_children(path, root, components, names, excludes, cancelled?) do
    names
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
      child = components ++ [name]

      case walk(Path.join(path, name), root, child, excludes, cancelled?) do
        {:ok, entries} -> {:cont, {:ok, acc ++ entries}}
        error -> {:halt, error}
      end
    end)
  end

  defp create_staging(plan, opts) do
    stage = staging(plan.destination)
    _ = owned_remove(stage)

    with :ok <- File.mkdir_p(Path.join(stage, "data")),
         {:ok, records} <- copy_entries(plan, stage, opts),
         :ok <- write_metadata(stage, plan, records, opts),
         :ok <- validate(stage) do
      :ok
    else
      error ->
        _ = owned_remove(stage)
        error
    end
  end

  defp copy_entries(plan, stage, opts) do
    sources =
      Keyword.get(opts, :sources, catalog())
      |> Map.new(fn source ->
        source = Map.new(source)
        {source |> Map.fetch!(:key) |> to_string(), Map.fetch!(source, :path)}
      end)

    progress = Keyword.get(opts, :progress, fn _ -> :ok end)
    cancelled? = Keyword.get(opts, :cancelled?, fn -> false end)

    Enum.reduce_while(plan.entries, {:ok, []}, fn entry, {:ok, records} ->
      source = Path.join([Map.fetch!(sources, entry.root) | entry.components])
      relative = Path.join(["data", entry.root | entry.components])
      target = Path.join(stage, relative)

      result =
        case entry.type do
          :directory -> File.mkdir_p(target)
          :regular -> copy_file(source, target, entry, cancelled?, progress)
        end

      case result do
        :ok when entry.type == :directory ->
          {:cont, {:ok, records}}

        {:ok, hash} ->
          progress.(%{phase: :copying, path: relative, bytes: entry.size})
          {:cont, {:ok, records ++ [%{path: relative, size: entry.size, sha256: hash}]}}

        {:error, _} = error ->
          {:halt, error}

        :ok ->
          {:halt, {:error, :copy_failed}}
      end
    end)
  end

  defp copy_file(source, target, expected, cancelled?, progress) do
    part = target <> ".part"
    File.mkdir_p!(Path.dirname(target))

    with {:ok, before} <- File.lstat(source),
         true <-
           (before.type == :regular && before.size == expected.size &&
              before.mtime == expected.mtime) || {:error, :source_changed},
         {:ok, input} <- File.open(source, [:read, :binary]),
         {:ok, output} <- File.open(part, [:write, :binary, :exclusive]) do
      result = stream(input, output, :crypto.hash_init(:sha256), 0, cancelled?, progress)
      File.close(input)

      result =
        with {:ok, hash, size} <- result,
             :ok <- :file.sync(output),
             :ok <- File.close(output),
             {:ok, after_stat} <- File.lstat(source),
             true <- same?(before, after_stat) || {:error, :source_changed},
             :ok <- File.rename(part, target),
             {:ok, copied} <- hash_file(target),
             true <- (copied == hash && size == expected.size) || {:error, :checksum_mismatch} do
          {:ok, Base.encode16(hash, case: :lower)}
        end

      if match?({:error, _}, result), do: File.rm(part)
      result
    end
  end

  defp stream(input, output, hash, size, cancelled?, progress) do
    cond do
      cancelled?.() ->
        {:error, :cancelled}

      true ->
        case IO.binread(input, @chunk) do
          :eof ->
            {:ok, :crypto.hash_final(hash), size}

          {:error, reason} ->
            {:error, {:read, reason}}

          bytes ->
            :ok = IO.binwrite(output, bytes)
            progress.(%{phase: :copying, bytes: byte_size(bytes)})

            stream(
              input,
              output,
              :crypto.hash_update(hash, bytes),
              size + byte_size(bytes),
              cancelled?,
              progress
            )
        end
    end
  end

  defp write_metadata(stage, plan, records, opts) do
    sums = Enum.map_join(records, "", &"#{&1.sha256}  #{&1.path}\n")

    manifest = %{
      format_version: @version,
      complete: true,
      created_at: Keyword.get(opts, :created_at),
      firmware: Keyword.get(opts, :firmware, Application.spec(:mayonnaios, :vsn) |> to_string()),
      device: Keyword.get(opts, :device, MayonnaiOS.Device.current!().id |> to_string()),
      sources: plan.sources,
      absent_sources: plan.absent,
      exclusions: configured_exclusions(opts),
      files: records
    }

    with :ok <- atomic_write(Path.join(stage, "SHA256SUMS"), sums),
         {:ok, json} <- Jason.encode(manifest),
         :ok <- atomic_write(Path.join(stage, "manifest.json"), json <> "\n") do
      :ok
    end
  end

  defp atomic_write(path, bytes) do
    part = path <> ".part"

    with {:ok, io} <- File.open(part, [:write, :binary, :exclusive]),
         :ok <- IO.binwrite(io, bytes),
         :ok <- :file.sync(io),
         :ok <- File.close(io),
         :ok <- File.rename(part, path) do
      :ok
    else
      error ->
        File.rm(part)
        error
    end
  end

  defp publish(destination) do
    current = current(destination)
    previous = previous(destination)
    stage = staging(destination)

    with :ok <- maybe_remove_previous(previous),
         :ok <- maybe_rotate_current(current, previous),
         :ok <- File.rename(stage, current),
         :ok <- validate(current) do
      _ = owned_remove(previous)
      :ok
    else
      error ->
        if not File.exists?(current) and File.dir?(previous), do: File.rename(previous, current)
        error
    end
  end

  defp recover(destination) do
    current = current(destination)
    previous = previous(destination)
    _ = owned_remove(staging(destination))

    cond do
      valid?(current) ->
        :ok

      valid?(previous) ->
        _ = owned_remove(current)
        File.rename(previous, current)

      File.exists?(current) or File.exists?(previous) ->
        {:error, :invalid_existing_backup}

      true ->
        :ok
    end
  end

  defp maybe_remove_previous(path) do
    cond do
      not File.exists?(path) -> :ok
      valid?(path) -> owned_remove(path)
      true -> {:error, :invalid_previous}
    end
  end

  defp maybe_rotate_current(current, previous) do
    cond do
      not File.exists?(current) -> :ok
      valid?(current) -> File.rename(current, previous)
      true -> {:error, :invalid_current}
    end
  end

  defp unique_safe_records(records) do
    paths = Enum.map(records, & &1["path"])

    cond do
      Enum.any?(paths, &(not safe_relative?(&1))) ->
        {:error, :unsafe_path}

      length(paths) != length(Enum.uniq(paths)) ->
        {:error, :duplicate_path}

      Enum.any?(records, &(not is_integer(&1["size"]) or not is_binary(&1["sha256"]))) ->
        {:error, :invalid_manifest}

      true ->
        :ok
    end
  end

  defp verify_records(root, records) do
    Enum.reduce_while(records, :ok, fn record, :ok ->
      path = Path.join(root, record["path"])

      with {:ok, stat} <- File.stat(path),
           true <-
             (stat.type == :regular && stat.size == record["size"]) || {:error, :missing_file},
           {:ok, hash} <- hash_file(path),
           true <-
             Base.encode16(hash, case: :lower) == record["sha256"] || {:error, :checksum_mismatch} do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp hash_file(path) do
    with {:ok, io} <- File.open(path, [:read, :binary]) do
      result = hash_stream(io, :crypto.hash_init(:sha256))
      File.close(io)
      result
    end
  end

  defp hash_stream(io, hash) do
    case IO.binread(io, @chunk) do
      :eof -> {:ok, :crypto.hash_final(hash)}
      {:error, reason} -> {:error, {:read, reason}}
      bytes -> hash_stream(io, :crypto.hash_update(hash, bytes))
    end
  end

  defp destination_ready(path) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.type == :directory || {:error, :destination_absent},
         :ok <- writable_probe(path) do
      :ok
    else
      {:error, :enoent} -> {:error, :destination_absent}
      error -> error
    end
  end

  defp writable_probe(path) do
    probe = Path.join(path, ".mayonnaios-backup-probe-#{System.unique_integer([:positive])}")

    case File.write(probe, <<>>, [:exclusive]) do
      :ok -> File.rm(probe)
      {:error, reason} -> {:error, {:destination_read_only, reason}}
    end
  end

  defp free_bytes(path) do
    case System.cmd("df", ["-Pk", path], stderr_to_stdout: true) do
      {output, 0} ->
        case output |> String.split("\n", trim: true) |> List.last() |> String.split() do
          [_fs, _blocks, _used, available | _] -> {:ok, String.to_integer(available) * 1024}
          _ -> {:error, :space_unknown}
        end

      _ ->
        {:error, :space_unknown}
    end
  rescue
    _ -> {:error, :space_unknown}
  end

  defp safe_components(components) do
    if Enum.all?(components, fn name ->
         is_binary(name) and String.valid?(name) and name not in ["", ".", ".."] and
           not String.contains?(name, ["/", <<0>>])
       end), do: :ok, else: {:error, :unsafe_name}
  end

  defp safe_relative?(path) when is_binary(path) do
    Path.type(path) == :relative and safe_components(String.split(path, "/")) == :ok
  end

  defp safe_relative?(_), do: false

  defp excluded?(components, excludes),
    do: Enum.any?(excludes, &List.starts_with?(components, &1))

  defp same?(a, b), do: a.type == b.type and a.size == b.size and a.mtime == b.mtime
  defp valid?(path), do: File.dir?(path) and validate(path) == :ok

  defp configured_exclusions(opts),
    do:
      Keyword.get(opts, :sources, catalog())
      |> Enum.flat_map(&(Map.new(&1) |> Map.get(:exclude, [])))

  defp owned_remove(path) do
    if File.dir?(path) and String.starts_with?(Path.basename(path), "."),
      do: File.rm_rf(path) |> elem(0),
      else: :ok
  end

  defp destination, do: Application.fetch_env!(:mayonnaios, :backup_destination)
  defp base(destination), do: Path.join(destination, @layout)
  defp current(destination), do: Path.join(base(destination), "current")
  defp staging(destination), do: Path.join(base(destination), ".staging")
  defp previous(destination), do: Path.join(base(destination), ".previous")
end
