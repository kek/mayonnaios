defmodule MayonnaiOS.Pickles.Store do
  @moduledoc """
  Pickles on disk: install, list, read manifests, delete.

  A pickle is a directory on the writable partition holding a `pickle.json`
  manifest and the Lua it names. This module owns that layout and nothing
  else -- no process, no cache, the same philosophy as `MayonnaiOS.Programs`:
  what `list/1` says is what the filesystem contains right now.

  ## Layout

      /root/pickles/
        tuya-lamps/
          pickle.json
          main.lua
        .state/
          tuya-lamps.json    <- mayo.storage lives here, OUTSIDE the pickle
        .tmp/                <- staging for installs

  `mayo.storage` data is under `.state/` rather than inside the pickle's own
  directory because installs replace that directory wholesale -- an upgrade
  that silently wiped the app's remembered state would make every reinstall a
  factory reset. State survives reinstalls and is removed on `delete/2`.

  ## The manifest

      {
        "name": "tuya-lamps",             required, must match the directory
        "version": "1.0.0",               optional
        "description": "Lamp control",    optional
        "main": "main.lua",               optional, this is the default
        "capabilities": ["lan", "timers"],
        "hosts": ["api.sunrise-sunset.org"],
        "autostart": true
      }

  `capabilities` is the sandbox contract: only what is named here is injected
  into the Lua state, and an unknown name fails the install rather than being
  ignored -- a typo that silently granted nothing would look exactly like the
  sandbox being broken. `hosts`, when present, narrows the `http` capability
  to those hosts.

  ## Trust

  A pickle tarball is untrusted input from the network, uploaded with no
  authentication like everything else on `MayonnaiOS.Web`. The containment is
  therefore not the transport and not the archive: member names are checked
  against traversal before extraction, the manifest is validated before the
  directory is published, and everything the script can *do* at runtime is
  decided by `MayonnaiOS.Pickles.Sandbox`, not by anything in the archive.
  """

  @known_capabilities ~w(http lan storage timers)

  @type manifest :: %{
          name: String.t(),
          version: String.t(),
          description: String.t(),
          main: String.t(),
          capabilities: [String.t()],
          hosts: [String.t()] | nil,
          autostart: boolean()
        }

  @doc """
  The capability names a manifest may request.
  """
  def known_capabilities, do: @known_capabilities

  @doc """
  Whether `name` can name a pickle.

  The name becomes a directory under the root and a URL segment, so the
  alphabet is the safe intersection: lowercase, digits, `-` and `_`, starting
  with an alphanumeric. Rejected rather than repaired, like `Library` does
  with filenames -- a repaired name is a name the uploader did not use.
  """
  def valid_name?(name) when is_binary(name), do: name =~ ~r/^[a-z0-9][a-z0-9_-]{0,31}$/
  def valid_name?(_), do: false

  @doc """
  Installed pickles under `root`, sorted by name.

  A directory whose manifest does not parse is returned with an `:error`
  field rather than dropped, for the same reason `Programs` renders missing
  binaries: an invisible failure looks exactly like success.
  """
  @spec list(String.t()) :: [manifest() | %{name: String.t(), error: term()}]
  def list(root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.filter(&(valid_name?(&1) and File.dir?(Path.join(root, &1))))
        |> Enum.map(fn name ->
          case manifest(root, name) do
            {:ok, manifest} -> manifest
            {:error, reason} -> %{name: name, error: reason}
          end
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  The validated manifest of the installed pickle `name`.
  """
  @spec manifest(String.t(), String.t()) :: {:ok, manifest()} | {:error, term()}
  def manifest(root, name) do
    with true <- valid_name?(name) || {:error, :bad_name},
         {:ok, body} <- File.read(Path.join([root, name, "pickle.json"])),
         {:ok, manifest} <- parse_manifest(body, name) do
      {:ok, manifest}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The directory of pickle `name`.
  """
  def dir(root, name), do: Path.join(root, name)

  @doc """
  Where `mayo.storage` for pickle `name` persists.
  """
  def state_path(root, name), do: Path.join([root, ".state", "#{name}.json"])

  @doc """
  Install the `.tar.gz` at `tarball` as pickle `name`. Returns the manifest.

  The archive may contain the files at its top level or inside a single
  directory -- `tar czf pickle.tar.gz -C tuya-lamps .` and
  `tar czf pickle.tar.gz tuya-lamps` both work, because whichever a person
  types first should not be the one that fails.

  Extraction is staged and the swap is a rename, so a running pickle's
  directory is never half-written: the old directory is moved aside, the new
  one moved in, and only then is the old one removed.
  """
  @spec install(String.t(), String.t(), String.t()) :: {:ok, manifest()} | {:error, term()}
  def install(root, name, tarball) do
    with true <- valid_name?(name) || {:error, :bad_name},
         :ok <- check_members(tarball),
         {:ok, staged} <- extract(root, name, tarball),
         {:ok, content} <- content_dir(staged),
         {:ok, manifest} <- read_staged_manifest(content, name),
         {:ok, _} <- publish(content, root, name) do
      File.rm_rf(staged)
      {:ok, manifest}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Remove pickle `name` and its remembered state.
  """
  @spec delete(String.t(), String.t()) :: :ok | {:error, term()}
  def delete(root, name) do
    with true <- valid_name?(name) || {:error, :bad_name},
         true <- File.dir?(dir(root, name)) || {:error, :enoent} do
      File.rm_rf(dir(root, name))
      File.rm(state_path(root, name))
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # -- install steps ---------------------------------------------------------

  # Never extract paths you have not looked at. :erl_tar refuses names that
  # escape the destination in recent OTP, but that is its policy and this is
  # our boundary; checking here means the answer does not change with the
  # runtime.
  defp check_members(tarball) do
    case :erl_tar.table(String.to_charlist(tarball), [:compressed]) do
      {:ok, members} ->
        bad =
          Enum.find(members, fn member ->
            path = to_string(member)
            String.starts_with?(path, "/") or ".." in Path.split(path)
          end)

        if bad, do: {:error, {:bad_member, to_string(bad)}}, else: :ok

      {:error, reason} ->
        {:error, {:not_a_tarball, reason}}
    end
  end

  defp extract(root, name, tarball) do
    staged = Path.join([root, ".tmp", "#{name}.d"])
    File.rm_rf(staged)
    File.mkdir_p!(staged)

    case :erl_tar.extract(String.to_charlist(tarball), [
           :compressed,
           {:cwd, String.to_charlist(staged)}
         ]) do
      :ok ->
        {:ok, staged}

      {:error, reason} ->
        File.rm_rf(staged)
        {:error, {:extract, reason}}
    end
  end

  # Top-level pickle.json wins; otherwise a single directory is descended
  # into. Anything else is ambiguous and rejected with a reason that names
  # the problem.
  defp content_dir(staged) do
    cond do
      File.exists?(Path.join(staged, "pickle.json")) ->
        {:ok, staged}

      match?([_], File.ls!(staged)) and File.dir?(Path.join(staged, hd(File.ls!(staged)))) ->
        {:ok, Path.join(staged, hd(File.ls!(staged)))}

      true ->
        {:error, :no_manifest}
    end
  end

  defp read_staged_manifest(content, name) do
    with {:ok, body} <- File.read(Path.join(content, "pickle.json")),
         {:ok, manifest} <- parse_manifest(body, name),
         true <-
           File.exists?(Path.join(content, manifest.main)) || {:error, {:no_main, manifest.main}} do
      {:ok, manifest}
    else
      {:error, :enoent} -> {:error, :no_manifest}
      {:error, reason} -> {:error, reason}
    end
  end

  # Old aside, new in, old gone -- in that order, so a reader either sees the
  # previous install whole or the new one whole.
  defp publish(content, root, name) do
    final = dir(root, name)
    old = Path.join([root, ".tmp", "#{name}.old"])
    File.rm_rf(old)

    had_old = File.dir?(final)
    if had_old, do: File.rename!(final, old)

    case File.rename(content, final) do
      :ok ->
        File.rm_rf(old)
        {:ok, final}

      {:error, reason} ->
        if had_old, do: File.rename(old, final)
        {:error, {:publish, reason}}
    end
  end

  # -- manifest --------------------------------------------------------------

  defp parse_manifest(body, name) do
    case decode(body) do
      {:ok, %{} = raw} -> validate_manifest(raw, name)
      {:ok, _} -> {:error, :bad_manifest}
      :error -> {:error, :bad_manifest}
    end
  end

  defp validate_manifest(raw, name) do
    capabilities = Map.get(raw, "capabilities", [])
    hosts = Map.get(raw, "hosts")

    cond do
      raw["name"] != name ->
        {:error, {:name_mismatch, raw["name"]}}

      not (is_list(capabilities) and Enum.all?(capabilities, &(&1 in @known_capabilities))) ->
        {:error, {:unknown_capability, capabilities -- @known_capabilities}}

      not (is_nil(hosts) or (is_list(hosts) and Enum.all?(hosts, &is_binary/1))) ->
        {:error, :bad_hosts}

      not plain_filename?(Map.get(raw, "main", "main.lua")) ->
        {:error, :bad_main}

      true ->
        {:ok,
         %{
           name: name,
           version: to_string(Map.get(raw, "version", "0")),
           description: to_string(Map.get(raw, "description", "")),
           main: Map.get(raw, "main", "main.lua"),
           capabilities: capabilities,
           hosts: hosts,
           autostart: Map.get(raw, "autostart", false) == true
         }}
    end
  end

  # The main script is a name inside the pickle's own directory, not a path.
  defp plain_filename?(name) when is_binary(name),
    do: name != "" and Path.basename(name) == name and not String.starts_with?(name, ".")

  defp plain_filename?(_), do: false

  defp decode(body) do
    {:ok, :json.decode(body)}
  rescue
    _ -> :error
  end
end
