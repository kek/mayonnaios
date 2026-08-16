defmodule ScenicRg40xxv.Bundle do
  @moduledoc """
  Installs content onto the writable partition, out of band from firmware.

  RetroArch, its cores and eventually ROMs are *content*, not firmware. This
  device's rootfs is a read-only squashfs, 66.5 MB and 100% full, written whole
  on every A/B update; the application partition is f2fs with 13.4 GB free.
  Putting a ~100 MB emulator in the first would mean resizing partitions in the
  board support package and reflashing an operating system to update a core.
  So it goes in the second, and this module puts it there.

  See `docs/retroarch-provisioning.md` for the decision and the measurements.

  ## What the device can actually do

  Every choice here was forced by what is in the image, checked rather than
  assumed:

      tar  absent    xz  absent    gzip  absent    curl  absent    wget  absent

  There is no archive tool and no HTTP client on this system. So fetching is
  `:httpc`, unpacking is `:erl_tar`, and hashing is `:crypto` -- all from OTP,
  which is present because the BEAM is. `:erl_tar` reads gzip and not xz, which
  is why bundles are `.tar.gz` despite xz being the obvious choice for size.

  Execution from the target directory was also verified rather than assumed:
  `/dev/mmcblk0p4` is mounted `nodev` but **not** `noexec`, and a script
  written there, chmod 0755, runs.

  ## Trust

  The checksum is the trust anchor, not the transport. A bundle's SHA-256 is
  configured in the firmware, so it is as trustworthy as the image itself,
  while the tarball comes over the network from wherever the build published
  it. The payload is therefore hashed **before** it is unpacked -- never
  extract bytes you have not authenticated, particularly not an archive that
  gets to choose its own path names.

  ## Layout

      /root/bundles/
        retroarch/
          1.22.2/          <- unpacked here, one directory per version
          current -> 1.22.2
          installed.json

  Versions are kept in separate directories and switched by moving a symlink,
  so an install never overwrites the running copy and a failed one leaves the
  previous version intact. `ScenicRg40xxv.Programs` re-stats `installed?` on
  every call, so a program under `current/` appears in the menu as soon as it
  lands, with no restart.
  """

  require Logger

  @type spec :: %{name: String.t(), version: String.t(), url: String.t(), sha256: String.t()}

  @doc """
  Where bundles are installed. Configurable so tests do not touch a real
  partition; the default is on the f2fs application partition.
  """
  def root, do: Application.get_env(:scenic_rg40xxv, :bundle_root, "/root/bundles")

  @doc """
  The directory a bundle's `current` symlink points into, or `nil`.
  """
  def current(name, root \\ root()) do
    path = Path.join([root, name, "current"])
    if File.exists?(path), do: path, else: nil
  end

  @doc """
  What is installed for `name`, from its manifest, or `nil`.
  """
  def installed(name, root \\ root()) do
    with {:ok, body} <- File.read(manifest_path(name, root)),
         {:ok, manifest} <- decode(body) do
      manifest
    else
      _ -> nil
    end
  end

  @doc """
  Fetch, verify and install a bundle. Idempotent.

  Returns `{:ok, :already_installed}`, `{:ok, path}`, or `{:error, reason}`.
  """
  @spec install(spec(), keyword()) ::
          {:ok, :already_installed} | {:ok, String.t()} | {:error, term()}
  def install(spec, opts \\ []) do
    root = Keyword.get(opts, :root, root())

    if installed?(spec, root) do
      {:ok, :already_installed}
    else
      with {:ok, tarball} <- download(spec, root),
           result <- install_tarball(tarball, spec, root) do
        File.rm(tarball)
        result
      end
    end
  end

  @doc """
  Verify and unpack an already-downloaded tarball.

  Split out from `install/2` because everything interesting happens here and
  none of it needs a network: the checksum gate, the extraction, and the
  atomic swap. The download is the thin part.
  """
  @spec install_tarball(String.t(), spec(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def install_tarball(tarball, spec, root) do
    with :ok <- verify(tarball, spec.sha256),
         {:ok, staged} <- extract(tarball, spec, root),
         {:ok, final} <- publish(staged, spec, root) do
      write_manifest(spec, root)
      Logger.info("[bundle] installed #{spec.name} #{spec.version}")
      {:ok, final}
    end
  end

  @doc """
  Whether this exact version and checksum is already installed and present.
  """
  def installed?(spec, root \\ root()) do
    case installed(spec.name, root) do
      %{"version" => v, "sha256" => s} ->
        # The manifest alone is not enough. It records intent; the directory
        # is the fact. A wiped data partition or a half-deleted version would
        # otherwise read as installed and the menu would offer a program that
        # is not there.
        v == spec.version and s == spec.sha256 and File.dir?(version_dir(spec, root))

      _ ->
        false
    end
  end

  # -- steps -----------------------------------------------------------------

  defp download(spec, root) do
    tmp = Path.join(root, ".tmp")
    File.mkdir_p!(tmp)

    # Same filesystem as the destination, so the later rename is atomic rather
    # than a copy across devices.
    target = Path.join(tmp, "#{spec.name}-#{spec.version}.tar.gz")
    File.rm(target)

    Logger.info("[bundle] fetching #{spec.url}")

    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    request = {String.to_charlist(spec.url), []}
    http_opts = [timeout: :infinity, connect_timeout: 30_000, ssl: ssl_opts()]

    # Streamed to a file rather than held in memory: this device has 1 GB of
    # RAM and the payload is ~100 MB, so buffering it would be a needless
    # fraction of the machine.
    case :httpc.request(:get, request, http_opts, stream: String.to_charlist(target)) do
      {:ok, :saved_to_file} -> {:ok, target}
      {:ok, {{_, status, _}, _, _}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, {:http, reason}}
    end
  end

  # TLS verification is defence in depth here rather than the trust anchor --
  # the SHA-256 below is what actually decides whether these bytes are used --
  # but an unverified connection is still not worth shipping.
  defp ssl_opts do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  rescue
    # A system with no CA store should fail loudly at the checksum, not fall
    # back to an unverified connection silently.
    _ -> [verify: :verify_peer, cacerts: []]
  end

  defp verify(tarball, expected) do
    actual = hash_file(tarball)

    if Base.encode16(actual, case: :lower) == String.downcase(expected) do
      :ok
    else
      {:error, {:checksum_mismatch, Base.encode16(actual, case: :lower), expected}}
    end
  end

  # Hashed in chunks for the same reason the download is streamed.
  defp hash_file(path) do
    path
    |> File.stream!(2 * 1024 * 1024)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
  end

  defp extract(tarball, spec, root) do
    staged = Path.join([root, ".tmp", "#{spec.name}-#{spec.version}.d"])
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

  # Move the staged tree into place, then repoint `current`. In that order:
  # the symlink is the only thing anything else reads, so it must not point at
  # a directory that is still being written.
  defp publish(staged, spec, root) do
    final = version_dir(spec, root)
    File.rm_rf(final)
    File.mkdir_p!(Path.dirname(final))

    with :ok <- File.rename(staged, final),
         :ok <- link_current(spec, root) do
      {:ok, final}
    else
      {:error, reason} -> {:error, {:publish, reason}}
    end
  end

  defp link_current(spec, root) do
    link = Path.join([root, spec.name, "current"])
    File.rm(link)
    File.ln_s(spec.version, link)
  end

  defp write_manifest(spec, root) do
    manifest = %{
      "name" => spec.name,
      "version" => spec.version,
      "sha256" => String.downcase(spec.sha256),
      "url" => spec.url
    }

    File.write(manifest_path(spec.name, root), encode(manifest))
  end

  # -- paths and JSON --------------------------------------------------------

  defp version_dir(spec, root), do: Path.join([root, spec.name, spec.version])
  defp manifest_path(name, root), do: Path.join([root, name, "installed.json"])

  # JSON via the OTP module rather than a dependency: this is two flat maps of
  # strings, and the app has no other reason to carry a JSON library.
  defp encode(map), do: :json.encode(map) |> IO.iodata_to_binary()

  defp decode(body) do
    {:ok, :json.decode(body)}
  rescue
    _ -> :error
  end
end
