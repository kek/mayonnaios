defmodule MayonnaiOS.Update do
  @moduledoc """
  Checks GitHub for a newer release, downloads its firmware asset, and
  applies it with `fwup` -- the online half of what `mix upload` does from a
  dev machine.

  This is the logic; `MayonnaiOS.Update.App` is the menu app that drives it
  from a button and `MayonnaiOS.Scene.Update` is what the panel shows. Split
  the same way `MayonnaiOS.Bundle` is split from the program rows that
  install one: the network and the disk are the thin, hard-to-test part, so
  every step here takes its I/O through an injectable argument and defaults
  to the real thing, the way `MayonnaiOS.Files.space/1` and
  `MayonnaiOS.Launcher.Signals` do.

  ## The three steps, and what each trusts

      check/1     GitHub's releases API, parsed into "is there a newer
                   tag, and does it have a firmware asset for this target"
      download/2  streamed straight to a file, like `MayonnaiOS.Bundle` --
                   this device has 1 GB of RAM and a firmware image is
                   tens of megabytes
      apply/2     `fwup -t upgrade`, the same task `mix upload` invokes over
                   SSH, against whichever slot is not currently running

  There is no checksum gate here the way there is in `MayonnaiOS.Bundle`.
  `fwup` already has one: every Nerves `.fw` is itself signed/framed and
  `fwup` refuses a corrupt or truncated one before it touches the inactive
  partition, so the trust anchor for firmware is `fwup`'s own validation
  rather than a hash carried alongside the download the way a bundle's is.
  TLS on the download is still checked -- see `MayonnaiOS.Bundle` for why
  that is defence in depth rather than the whole story.

  ## Why this device needs `Nerves.Runtime.validate_firmware/0` and does not call it

  `nerves_fw_autovalidate=0` on this board (see `uboot/uboot.env` in
  `nerves_system_rg40xxv`): a freshly applied slot is **not** trusted by
  U-Boot until something marks it validated, and if nothing does before the
  next reboot, U-Boot reverts to the slot that was already running. That is
  deliberate -- the alternative is a kernel that fails to boot leaving the
  device stuck, unrecoverable without reflashing the card -- but it means
  *something* in the image has to call `validate_firmware/0` after the new
  firmware has actually come up.

  This project already has that something, system-wide:

      config :nerves_runtime, startup_guard_enabled: true

  in `config/target.exs`. `Nerves.Runtime.StartupGuard` validates the
  running slot once every OTP application in this release has started, on
  *every* boot -- not only the one after an update. So the flow this module
  drives is: apply the new firmware, offer a reboot, and let the boot that
  follows validate itself the same way every other boot on this device
  does. Nothing here calls `validate_firmware/0` a second time, because a
  second, update-specific validator racing the StartupGuard is exactly the
  latch bug documented in `fwup-ops.conf`'s `task validate` -- one validator
  is the point.

  What that leaves as a real risk, and one this module cannot remove: if the
  device is powered off during the *first* boot of the new firmware, before
  every application has started, U-Boot reverts on the next boot. That is
  the same risk `mix upload` already carries and is not new here -- it is
  the reason `nerves_fw_booted`/`nerves_fw_validated` exist at all.

  ## What is not handled

  `apply/2` only ever writes the inactive slot, so a download or apply that
  is interrupted -- including by leaving the app's menu screen, which stops
  its process -- never touches the firmware that is currently running.
  Retrying is always safe: the worst case is a half-written inactive slot
  that the next attempt overwrites.
  """

  require Logger

  @default_repo "kek/mayonnaios"

  @type asset :: %{name: String.t(), url: String.t(), size: non_neg_integer() | nil}

  @type check_result :: %{
          current: String.t(),
          latest: String.t(),
          tag: String.t(),
          comparable?: boolean(),
          available?: boolean(),
          notes: String.t() | nil,
          published_at: String.t() | nil,
          asset: asset() | nil
        }

  @doc """
  The version of the firmware actually running, from the OTP release's own
  `.app` file -- the same number `mix.exs`'s `@version` compiles in.

  `"0.0.0"` if the application spec has not loaded, which cannot happen
  outside of a test that has gone out of its way to unload it, but a
  version string is more useful there than a crash.
  """
  @spec running_version() :: String.t()
  def running_version do
    case Application.spec(:mayonnaios, :vsn) do
      nil -> "0.0.0"
      vsn -> List.to_string(vsn)
    end
  end

  @doc """
  Ask GitHub whether a newer release than `current_version` exists, and
  whether it carries a firmware asset for `target`.

  Options, all for tests -- the defaults are what the device actually uses:

    * `:repo` -- `"owner/name"`, default `"kek/mayonnaios"`
    * `:target` -- the Nerves target to find an asset for, default
      `Nerves.Runtime.mix_target/0`
    * `:current_version` -- default `running_version/0`
    * `:fetch` -- `(url -> {:ok, %{status: integer, body: binary}} |
      {:error, term}})`, default an HTTPS GET through `:httpc`

  Never raises. `:no_releases` is returned for a repo with no releases at
  all -- GitHub's `/releases/latest` is a 404 in that case, not an empty
  list -- which is where this project is today.
  """
  @spec check(keyword()) :: {:ok, check_result()} | {:error, term()}
  def check(opts \\ []) do
    repo = Keyword.get(opts, :repo, Application.get_env(:mayonnaios, :update_repo, @default_repo))
    target = Keyword.get(opts, :target, Nerves.Runtime.mix_target())
    current = Keyword.get(opts, :current_version, running_version())
    fetch = Keyword.get(opts, :fetch, &http_get/1)

    url = "https://api.github.com/repos/#{repo}/releases/latest"

    with {:ok, %{status: 200, body: body}} <- fetch.(url),
         {:ok, release} <- decode(body) do
      {:ok, build_result(release, target, current)}
    else
      {:ok, %{status: 404}} -> {:error, :no_releases}
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, {:http, reason}}
      :error -> {:error, :invalid_response}
    end
  end

  @doc """
  How `current` compares to `latest`, both plain version strings.

  Uses `Version.compare/2`, which is stricter than a tag name: a release
  tagged `v1.2` rather than `v1.2.0` is not a version this can compare, and
  `{:error, :unparseable}` says so rather than guessing. `check/1` still
  reports the raw strings either way -- `comparable?` is what a screen uses
  to decide whether to trust `available?` at all.
  """
  @spec compare_versions(String.t(), String.t()) ::
          {:ok, :lt | :eq | :gt} | {:error, :unparseable}
  def compare_versions(current, latest) do
    {:ok, Version.compare(current, latest)}
  rescue
    Version.InvalidVersionError -> {:error, :unparseable}
  end

  @doc """
  A release tag as a bare version string: `"v1.2.0"` and `"1.2.0"` both
  become `"1.2.0"`. Only the leading `v`/`V` is stripped -- anything else
  odd about the tag is left in, for `compare_versions/2` to reject.
  """
  @spec normalize_tag(String.t()) :: String.t()
  def normalize_tag(tag) when is_binary(tag) do
    case tag do
      <<v, rest::binary>> when v in [?v, ?V] -> rest
      other -> other
    end
  end

  @doc """
  Whether `dest_dir`'s filesystem has room for `needed_bytes`, with a 5%
  margin on top -- `fwup` writes progressively rather than staging a whole
  second copy, but a download that lands exactly at the last free byte and
  a filesystem that is never quite as free as `df` says are both real, and
  a margin is cheaper than explaining either.

  `nil` for `needed_bytes` -- an asset with no reported size -- passes, since
  there is nothing to check against; the download itself still fails cleanly
  if the disk fills up.
  """
  @spec enough_space?(String.t(), non_neg_integer() | nil) :: boolean()
  def enough_space?(_dest_dir, nil), do: true

  def enough_space?(dest_dir, needed_bytes) do
    case MayonnaiOS.Files.space(dest_dir) do
      %{free: free} -> free >= needed_bytes + div(needed_bytes, 20)
      nil -> false
    end
  end

  @doc """
  Download `asset` to `dest`, streamed straight to disk.

  Refuses before it starts if `enough_space?/2` says there is not room, so a
  download that would fail with the disk full instead fails immediately with
  the number that explains why. Injectable `:get` is `(url, dest -> :ok |
  {:error, term})`, for tests; the default streams through `:httpc` the same
  way `MayonnaiOS.Bundle.install/2` does.
  """
  @spec download(asset(), String.t(), keyword()) :: :ok | {:error, term()}
  def download(asset, dest, opts \\ []) do
    get = Keyword.get(opts, :get, &http_get_to_file/2)

    if enough_space?(Path.dirname(dest), asset[:size]) do
      File.rm(dest)
      get.(asset.url, dest)
    else
      {:error, {:insufficient_space, asset[:size], Path.dirname(dest)}}
    end
  end

  @doc """
  Apply a downloaded `.fw` file to the inactive firmware slot with `fwup`'s
  `upgrade` task -- the same task `ssh_subsystem_fwup` runs for `mix upload`,
  the only difference being that the bytes are already a local file instead
  of arriving over a port's stdin.

  Options, for tests and for the one thing that varies on a real device:

    * `:devpath` -- default `Nerves.Runtime.KV.get("nerves_fw_devpath")`
    * `:fwup_path` -- default `System.find_executable("fwup")`
    * `:cmd` -- `(path, args, opts -> {output, status})`, default
      `System.cmd/3`

  Never touches the currently running slot: `fwup upgrade` always targets
  whichever one is not active, which is what makes retrying after any
  failure here safe.
  """
  @spec apply(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def apply(fw_path, opts \\ []) do
    devpath = Keyword.get(opts, :devpath, Nerves.Runtime.KV.get("nerves_fw_devpath"))
    fwup_path = Keyword.get(opts, :fwup_path, System.find_executable("fwup"))
    cmd = Keyword.get(opts, :cmd, &System.cmd/3)

    cond do
      is_nil(devpath) ->
        {:error, :no_devpath}

      is_nil(fwup_path) ->
        {:error, :fwup_not_found}

      true ->
        args = ["--apply", "--no-unmount", "-i", fw_path, "-t", "upgrade", "-d", devpath]

        case cmd.(fwup_path, args, stderr_to_stdout: true) do
          {output, 0} ->
            Logger.info("[update] fwup applied #{fw_path}")
            {:ok, output}

          {output, status} ->
            Logger.warning("[update] fwup exited #{status}: #{String.trim(output)}")
            {:error, {:fwup_failed, status, output}}
        end
    end
  end

  # -- release parsing ---------------------------------------------------------

  defp build_result(release, target, current) do
    tag = Map.get(release, "tag_name", "")
    latest = normalize_tag(tag)
    assets = Map.get(release, "assets", [])

    {comparable?, available?} =
      case compare_versions(current, latest) do
        {:ok, :lt} -> {true, true}
        {:ok, _eq_or_gt} -> {true, false}
        {:error, :unparseable} -> {false, false}
      end

    %{
      current: current,
      latest: latest,
      tag: tag,
      comparable?: comparable?,
      available?: available?,
      notes: Map.get(release, "body"),
      published_at: Map.get(release, "published_at"),
      asset: find_asset(assets, target)
    }
  end

  # An asset is this target's if it ends in ".fw" and names the target
  # somewhere in its filename -- "mayonnaios_rg40xxv.fw" -- rather than by a
  # fixed name, since nothing has published one yet to pin the convention
  # down further. `nil` when nothing matches: a release can exist with no
  # firmware asset for this device at all, and that is a state worth
  # showing rather than treating as "no update".
  defp find_asset(assets, target) do
    target_str = to_string(target)

    Enum.find_value(assets, fn asset ->
      name = Map.get(asset, "name", "")

      if String.ends_with?(name, ".fw") and String.contains?(name, target_str) do
        %{name: name, url: Map.get(asset, "browser_download_url"), size: Map.get(asset, "size")}
      end
    end)
  end

  defp decode(body) do
    {:ok, :json.decode(body)}
  rescue
    _ -> :error
  end

  # -- the real transport -------------------------------------------------------
  #
  # Both follow MayonnaiOS.Bundle's lead: :httpc and :ssl from OTP, verified
  # TLS as defence in depth. See that module's moduledoc for the "why not a
  # dependency" account -- it applies here unchanged.

  defp http_get(url) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    request = {String.to_charlist(url), user_agent()}
    http_opts = [timeout: 15_000, connect_timeout: 10_000, ssl: ssl_opts()]

    case :httpc.request(:get, request, http_opts, body_format: :binary) do
      {:ok, {{_line, status, _reason}, _headers, body}} -> {:ok, %{status: status, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp http_get_to_file(url, dest) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    request = {String.to_charlist(url), user_agent()}
    http_opts = [timeout: :infinity, connect_timeout: 30_000, ssl: ssl_opts()]

    case :httpc.request(:get, request, http_opts, stream: String.to_charlist(dest)) do
      {:ok, :saved_to_file} -> :ok
      {:ok, {{_, status, _}, _, _}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, {:http, reason}}
    end
  end

  # GitHub's API 403s a request with no User-Agent at all.
  defp user_agent, do: [{~c"User-Agent", ~c"mayonnaios-update"}]

  defp ssl_opts do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  rescue
    _ -> [verify: :verify_peer, cacerts: []]
  end
end
