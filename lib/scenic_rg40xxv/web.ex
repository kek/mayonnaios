defmodule ScenicRg40xxv.Web do
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
  written down here rather than left to be discovered. `ScenicRg40xxv.Library`
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

  alias ScenicRg40xxv.{Cores, Library}

  plug(:match)
  # No Plug.Parsers. See the moduledoc: bodies are streamed, never parsed
  # into memory or into a temp file. The only structured input this takes is
  # a core name in a URL segment.
  plug(:dispatch)

  @doc """
  The port to listen on. 80 so the address is just the hostname.
  """
  def port, do: Application.get_env(:scenic_rg40xxv, :web_port, 80)

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
    |> send_resp(200, ScenicRg40xxv.Web.Page.render())
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
    result =
      Library.receive_upload(system, filename, conn, fn c ->
        Plug.Conn.read_body(c, length: 1_000_000, read_length: 1_000_000)
      end)

    case result do
      {:ok, %{name: name, size: size}} ->
        json(conn, 201, %{"name" => name, "size" => size})

      {:error, reason} ->
        json(conn, status_for(reason), %{"error" => to_string(elem_or(reason))})
    end
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

  match _ do
    send_resp(conn, 404, "not found")
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
  defp status_for(_), do: 500

  defp elem_or(reason) when is_atom(reason), do: reason
  defp elem_or(reason) when is_tuple(reason), do: elem(reason, 0)
  defp elem_or(reason), do: inspect(reason)
end
