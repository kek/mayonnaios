defmodule MayonnaiOS.Web do
  @moduledoc """
  The upload UI: a page you open from a phone on the same WiFi.

  This is the thing that makes the device a console rather than a dev board.
  Getting a game onto it should not require a laptop, a toolchain, an SSH key
  and the knowledge that `scp -O` does not work here.

      http://nerves-5322903c.local/

  ## Uploading without a temp file

  Browsers post file inputs as `multipart/form-data`, and the usual handler
  for that is `Plug.Parsers` with `:multipart`, which writes each part to a
  `Plug.Upload` temp file and hands you the path. That is the wrong shape for
  this device twice over.

  `Plug.Upload` writes to `System.tmp_dir()`, which on Nerves is `/tmp` -- a
  **tmpfs**, which is to say RAM. This board has 1 GB of it. A 700 MB disc
  image would be written into memory and then copied to disk, and the first
  half of that is fatal.

  So the browser does not post a form. The page reads the file with `XHR` and
  sends the bytes as the raw body of a `PUT`, and the server streams them
  straight to their destination with `Plug.Conn.read_body/2`. Constant memory,
  one write, no temp file, and the upload progress bar comes free because XHR
  reports it.

  The filename travels in the URL rather than a header, so an upload is an
  ordinary addressable `PUT` to the path the file will occupy.

  ## What this does not have

  **No authentication.** This listens on every interface, and anything on the
  same network can upload a ROM, delete one, or install a core. That is the
  same trust model as a printer's web page, and for a handheld on a home
  network it is a reasonable default -- but it *is* a decision, and it is
  written down here rather than left to be discovered. `MayonnaiOS.Library`
  is what stops it from being worse than that: the writable area is one
  directory per configured system, filenames that could escape it are rejected
  rather than repaired, and extensions are checked against the system.

  **No TLS.** There is no certificate a handheld can present that a phone
  would accept without a warning, and a self-signed one teaches the habit of
  clicking through.

  Both are worth revisiting the first time this device is on a network its
  owner does not control.
  """

  use Plug.Router

  alias MayonnaiOS.{Cores, Library, Pickles}

  plug(:match)
  # No Plug.Parsers. See the moduledoc: bodies are streamed, never parsed
  # into memory or into a temp file. The only structured input this takes is
  # a core name in a URL segment.
  plug(:dispatch)

  @doc """
  The port to listen on. 80 so the address is just the hostname.
  """
  def port, do: Application.get_env(:mayonnaios, :web_port, 80)

  @doc """
  Child spec for the supervision tree.
  """
  def child_spec(_opts) do
    Supervisor.child_spec(
      {Bandit, plug: __MODULE__, port: port(), scheme: :http},
      id: __MODULE__
    )
  end

  get "/" do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, MayonnaiOS.Web.Page.render())
  end

  get "/api/library" do
    json(conn, 200, %{
      "systems" =>
        Enum.map(Library.index(), fn sys ->
          %{
            "key" => sys.key,
            "name" => sys.name,
            "extensions" => sys.extensions,
            "entries" => Enum.map(sys.entries, &%{"name" => &1.name, "size" => &1.size})
          }
        end),
      "cores" =>
        Enum.map(Cores.list(), fn c ->
          %{
            "key" => c.key,
            "label" => c.label,
            "version" => c.version,
            "systems" => c.systems,
            "installed" => c.installed,
            "available" => c.available
          }
        end),
      "free_bytes" => Library.free_bytes()
    })
  end

  put "/api/roms/:system/:filename" do
    filename = URI.decode(filename)

    # read_body/2 is passed by reference rather than called here, so the
    # streaming loop lives in Library with the file handle it is writing to
    # and this module never holds a chunk.
    #
    # The conn comes back out because Plug.Conn carries the adapter's state in
    # the struct: the one that went in is stale as soon as a chunk is read,
    # and replying on it would be replying on a description of the connection
    # from before the body arrived.
    case Library.receive_upload(system, filename, conn, &read_chunk/1) do
      {:ok, %{name: name, size: size}, conn} ->
        json(conn, 201, %{"name" => name, "size" => size})

      {:error, reason, conn} ->
        json(conn, status_for(reason), %{"error" => to_string(elem_or(reason))})
    end
  end

  # A megabyte at a time. Small enough that a rejected upload stops promptly,
  # large enough that a 700 MB image is not seven hundred round trips through
  # the loop.
  defp read_chunk(conn) do
    Plug.Conn.read_body(conn, length: 1_000_000, read_length: 1_000_000)
  end

  delete "/api/roms/:system/:filename" do
    case Library.delete(system, URI.decode(filename)) do
      :ok -> json(conn, 200, %{"deleted" => true})
      {:error, reason} -> json(conn, status_for(reason), %{"error" => to_string(elem_or(reason))})
    end
  end

  post "/api/cores/:name/install" do
    # Installing pulls a tarball over the network and can take a while. It runs
    # inside the request rather than in a task on purpose: the page has nowhere
    # to report a background failure to, and a request that takes twenty
    # seconds and then says what happened is more useful than one that returns
    # instantly and leaves the answer in the log.
    case Cores.install(name) do
      {:ok, :already_installed} -> json(conn, 200, %{"installed" => true, "changed" => false})
      {:ok, _} -> json(conn, 201, %{"installed" => true, "changed" => true})
      {:error, reason} -> json(conn, status_for(reason), %{"error" => inspect(reason)})
    end
  end

  # -- pickles ----------------------------------------------------------------
  #
  # The deploy loop for sandboxed Lua apps; see MayonnaiOS.Pickles. The same
  # trust model as everything above: anything on the network can install one,
  # and the containment is the sandbox the script runs in, not this door.

  get "/api/pickles" do
    json(conn, 200, %{"pickles" => Enum.map(Pickles.list(), &Pickles.jsonable/1)})
  end

  put "/api/pickles/:name" do
    # Read whole rather than streamed, unlike ROMs: a pickle is a few KB of
    # Lua and its ceiling is 5 MB, so the temp file is for :erl_tar (which
    # wants a name), not for memory.
    case read_all(conn, 5_000_000) do
      {:ok, body, conn} ->
        tarball = stage_upload(name, body)

        result = Pickles.install(name, tarball)
        File.rm(tarball)

        case result do
          {:ok, manifest} -> json(conn, 201, Pickles.jsonable(manifest))
          {:error, reason} -> json(conn, status_for(reason), %{"error" => inspect(reason)})
        end

      {:error, :too_large, conn} ->
        json(conn, 413, %{"error" => "too_large"})
    end
  end

  delete "/api/pickles/:name" do
    case Pickles.delete(name) do
      :ok -> json(conn, 200, %{"deleted" => true})
      {:error, reason} -> json(conn, status_for(reason), %{"error" => inspect(reason)})
    end
  end

  post "/api/pickles/:name/start" do
    case Pickles.start(name) do
      {:ok, _pid} -> json(conn, 200, %{"running" => true})
      {:error, reason} -> json(conn, status_for(reason), %{"error" => inspect(reason)})
    end
  end

  post "/api/pickles/:name/stop" do
    case Pickles.stop(name) do
      :ok -> json(conn, 200, %{"running" => false})
      {:error, reason} -> json(conn, status_for(reason), %{"error" => inspect(reason)})
    end
  end

  # Call a function the pickle's script defined. The body is a JSON array of
  # arguments, or empty for none. This endpoint is what makes a pickle a
  # remote control: the phone, the console and the Claude skill all press the
  # same button.
  post "/api/pickles/:name/call/:fname" do
    case read_all(conn, 64_000) do
      {:ok, body, conn} ->
        case decode_args(body) do
          {:ok, args} ->
            case Pickles.call(name, fname, args) do
              {:ok, results} ->
                json(conn, 200, %{"results" => Pickles.jsonable(results)})

              {:error, reason} ->
                json(conn, status_for(reason), %{"error" => inspect(reason)})
            end

          :error ->
            json(conn, 400, %{"error" => "body must be a JSON array of arguments"})
        end

      {:error, :too_large, conn} ->
        json(conn, 413, %{"error" => "too_large"})
    end
  end

  get "/api/pickles/:name/log" do
    case Pickles.info(name) do
      {:error, reason} ->
        json(conn, status_for(reason), %{"error" => inspect(reason)})

      info ->
        json(conn, 200, Pickles.jsonable(info))
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # Read a bounded body into memory; anything over the cap answers 413.
  defp read_all(conn, limit, acc \\ []) do
    case Plug.Conn.read_body(conn, length: limit, read_length: limit) do
      {:ok, chunk, conn} ->
        body = IO.iodata_to_binary([acc, chunk])

        if byte_size(body) <= limit do
          {:ok, body, conn}
        else
          {:error, :too_large, conn}
        end

      {:more, _chunk, conn} ->
        {:error, :too_large, conn}

      {:error, _reason} ->
        {:error, :too_large, conn}
    end
  end

  defp stage_upload(name, body) do
    dir = Path.join(Pickles.root(), ".tmp")
    File.mkdir_p!(dir)
    path = Path.join(dir, "upload-#{name}.tar.gz")
    File.write!(path, body)
    path
  end

  defp decode_args(""), do: {:ok, []}

  defp decode_args(body) do
    case :json.decode(body) do
      args when is_list(args) -> {:ok, args}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, :json.encode(body) |> IO.iodata_to_binary())
  end

  # A wrong filename is the client's fault and a full disk is not, and the
  # difference matters to whoever is looking at the phone.
  defp status_for(:unknown_system), do: 404
  defp status_for(:bad_name), do: 400
  defp status_for(:bad_extension), do: 415
  defp status_for(:too_large), do: 413
  defp status_for(:enoent), do: 404
  defp status_for(:unknown_core), do: 404
  defp status_for(:not_running), do: 409
  defp status_for(:no_such_function), do: 404
  defp status_for(:timeout), do: 504

  defp status_for(reason)
       when reason in [
              :bad_member,
              :not_a_tarball,
              :no_manifest,
              :bad_manifest,
              :bad_main,
              :bad_hosts,
              :name_mismatch,
              :unknown_capability,
              :no_main
            ],
       do: 400

  # Pickle errors carry their detail as tuples; the status comes from the tag.
  defp status_for(reason) when is_tuple(reason), do: status_for(elem(reason, 0))
  defp status_for(_), do: 500

  defp elem_or(reason) when is_atom(reason), do: reason
  defp elem_or(reason) when is_tuple(reason), do: elem(reason, 0)
  defp elem_or(reason), do: inspect(reason)
end
