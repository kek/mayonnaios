defmodule MayonnaiOS.Files do
  @moduledoc """
  The filesystem as the file manager is allowed to see it: a fixed set of
  roots, names that are checked rather than cleaned, and writes that are
  fsynced before they count as done.

  This module is the whole boundary. `MayonnaiOS.FileManager` holds a cursor
  and `MayonnaiOS.Scene.FileManager` draws it; neither of them ever builds a
  path.

  ## What is reachable, and why nothing else is

  A location is a **root key and a list of names** -- never a string:

      {:ok, here} = MayonnaiOS.Files.at("roms-1", ["snes"])
      {:ok, "/root/ROMS/snes"} = MayonnaiOS.Files.resolve(here)

  Every operation in this module takes locations. None of them takes a path,
  so there is no argument anywhere that a traversal could arrive in. The path
  is built here, by joining checked names onto a root that came from config.

  The roots come from the configuration this application already has --
  `:rom_roots`, `:bundle_root`, `:core_root` -- plus `/root` itself, because
  the writable partition is the thing a file manager on this device is for.
  Nothing names `/`: that is a 69 MB read-only squashfs and there is nothing
  a file manager could do to it. `:file_roots` overrides the list, which is
  how the tests point it at a temporary directory.

  ## Names are rejected, not repaired

  `safe_name/1` refuses:

    * `""`, `"."` and `".."` exactly
    * anything containing `/`, `\\` or a null byte
    * anything longer than 200 bytes, or not valid UTF-8

  `Path.basename/1` would turn `"../../bundles"` into `"bundles"`, which is
  safe and dishonest: it accepts a request that was trying to leave and leaves
  nothing in the log saying so. `MayonnaiOS.Library` takes the same line for
  the same reason, and this module deliberately reads the same way.

  One rule of Library's is **not** copied: a leading dot is allowed here.
  Library rejects dotfiles because an upload must not be able to land as one;
  here `/root/.config/retroarch` is one of the directories most worth looking
  at, and a file manager that cannot see the dotfiles on the disk is lying
  about what is on the disk.

  ## Symlinks are the honest caveat

  A checked name cannot leave a root. A symlink can, and following symlinks is
  not optional on this device: `bundles/retroarch/current` is one, and
  everything in RetroArch's core directory is one. So:

    * navigation and listing **follow** links, and say so -- an entry carries
      its target, and a link whose target is gone is marked broken. That is
      worth having rather than hiding: a dangling `.so` in the core directory
      looks like an installed core to anything that only lists names.
    * `delete/1` removes the **link**, never what it points at.
    * `copy/3` refuses a symlink source outright. Copying *through* a link is
      the one way a read could leave the roots, and the file it points at can
      be copied from where it actually lives.

  So the guarantee is: no name can leave a root, and no destructive operation
  acts on anything but the entry named. It is not "nothing outside /root can
  be read", because a symlink already in the tree can be followed, and saying
  otherwise would be a claim this code does not enforce.

  ## Every write is fsynced

  There is no `sync` on this device -- not the binary, not a busybox applet.
  A file written and not fsynced survives exactly as long as the page cache,
  and this handheld is switched off by pulling its power. That has already
  cost a set of ROMs once.

  So `copy/3` streams into a `.part` file beside the destination, calls
  `:file.sync/1` on the handle **while it is still open**, and only then
  renames it into place. Same directory, so the rename is atomic: an
  interrupted copy leaves a `.part`, never a half-written ROM that looks
  complete and fails three hours into a game. This is the shape
  `MayonnaiOS.Library.receive_upload/4` already uses for uploads.

  What cannot be done from here, stated rather than glossed: the *directory
  entry* is not fsynced, because OTP cannot open a directory to sync it. A
  rename or a delete is therefore durable only once the filesystem gets round
  to it. `move/3` within one filesystem is a rename and so has nothing to
  sync; across filesystems it copies -- and that copy is fsynced -- and then
  removes the source.

  ## What is deliberately not implemented

  `copy/3` takes a regular file and no directories, and `move/3` will move a
  directory only when the destination is on the same filesystem and the kernel
  can do it as a rename. A recursive copy of a directory on a 13 GB card is a
  long-running job that needs progress, cancellation and a free-space check
  per file; refusing it with `:eisdir` and `:exdev` is honest, whereas
  starting one inside the process that also reads the D-pad would freeze the
  UI for minutes.

  Nothing here overwrites. A destination that exists is `{:error, :eexist}`,
  because the only interesting file on this device is a save or a ROM and a
  file manager that silently replaces one is a file manager that eats them.
  """

  require Logger

  alias MayonnaiOS.{Bundle, Cores, Library}

  @typedoc "A root key plus the checked names below it. The only way to name a file."
  @type location :: %{root: String.t(), path: [String.t()]}

  @typedoc "A configured root: where browsing can start."
  @type place :: %{key: String.t(), path: String.t(), note: String.t()}

  @type entry :: %{
          name: String.t(),
          type: :directory | :regular | :missing | atom(),
          size: non_neg_integer() | nil,
          link: String.t() | nil,
          broken?: boolean()
        }

  @type reason ::
          :unknown_root
          | :bad_name
          | :is_root
          | :eexist
          | :eisdir
          | :enotdir
          | :enoent
          | :exdev
          | :enospc
          | :not_empty
          | :is_symlink
          | :same_path
          | atom()

  # 64 KB per read. Big enough that a 200 MB ROM is not four thousand
  # syscalls, small enough that eight of them in flight is nothing on a board
  # with 1 GB of RAM.
  @chunk 65_536

  @max_name 200

  # -- roots ------------------------------------------------------------------

  @doc """
  The roots browsing can start from, in the order they are offered.

  Derived from the configuration that already exists rather than written out
  again here: the ROM roots are `MayonnaiOS.Library.roots/0`, so the file
  manager and the library can never disagree about where games live, and a
  second card added to `:rom_roots` appears here with no code change.
  """
  @spec places() :: [place()]
  def places do
    case Application.get_env(:mayonnaios, :file_roots) do
      [_ | _] = configured -> Enum.map(configured, &normalize_place/1)
      _ -> default_places()
    end
  end

  defp default_places do
    roms =
      Library.roots()
      |> Enum.with_index(1)
      |> Enum.map(fn {path, index} ->
        %{key: "roms-#{index}", path: path, note: rom_note(index)}
      end)

    roms ++
      [
        %{key: "bundles", path: Bundle.root(), note: "installed bundles"},
        %{key: "cores", path: Cores.root(), note: "installed cores"},
        %{key: "root", path: "/root", note: "the writable partition"}
      ]
  end

  # The first ROM root is the one uploads are written to; see Library.root/0.
  # Saying which is which matters here, because this is the screen where
  # someone decides where to put a file.
  defp rom_note(1), do: "games, and where uploads land"
  defp rom_note(_), do: "games on another card, read as one library"

  defp normalize_place(place) when is_list(place), do: place |> Map.new() |> normalize_place()

  defp normalize_place(%{key: key, path: path} = place) do
    %{key: to_string(key), path: path, note: Map.get(place, :note, "")}
  end

  @doc "The configured root with this key, or `nil`."
  @spec place(String.t()) :: place() | nil
  def place(key), do: Enum.find(places(), &(&1.key == key))

  # -- locations --------------------------------------------------------------

  @doc """
  A location inside a root, with every name checked.

  The only constructor. An unknown root is an error rather than a path, and so
  is a name that could mean anything but itself.
  """
  @spec at(String.t(), [String.t()]) :: {:ok, location()} | {:error, reason()}
  def at(root_key, names \\ []) do
    with {:ok, _place} <- fetch_place(root_key),
         {:ok, names} <- safe_names(names) do
      {:ok, %{root: root_key, path: names}}
    end
  end

  @doc """
  One level down, by name.
  """
  @spec descend(location(), String.t()) :: {:ok, location()} | {:error, reason()}
  def descend(%{root: root, path: names}, name) do
    with {:ok, name} <- safe_name(name), do: at(root, names ++ [name])
  end

  @doc """
  One level up. At the top of a root, `nil` -- which is the list of roots.
  """
  @spec ascend(location()) :: location() | nil
  def ascend(%{path: []}), do: nil
  def ascend(%{path: names} = location), do: %{location | path: Enum.drop(names, -1)}

  @doc """
  The absolute path of a location.

  Re-checks every name rather than trusting the struct it was handed. Cheap,
  and it means a location assembled by hand somewhere else cannot become a
  path here.
  """
  @spec resolve(location()) :: {:ok, String.t()} | {:error, reason()}
  def resolve(%{root: root, path: names}) do
    with {:ok, place} <- fetch_place(root),
         {:ok, names} <- safe_names(names) do
      {:ok, Path.join([place.path | names])}
    end
  end

  def resolve(_other), do: {:error, :bad_name}

  @doc """
  The name of the thing a location points at, or `:is_root` for a root.

  An operation on a root is refused here rather than deeper down: `delete/1`
  on `%{root: "root", path: []}` would be `rm -rf /root`.
  """
  @spec basename(location()) :: {:ok, String.t()} | {:error, :is_root}
  def basename(%{path: []}), do: {:error, :is_root}
  def basename(%{path: names}), do: {:ok, List.last(names)}

  @doc """
  Whether a name may be used at all. Rejects; does not repair.
  """
  @spec safe_name(term()) :: {:ok, String.t()} | {:error, :bad_name}
  def safe_name(name) when is_binary(name) do
    cond do
      name in ["", ".", ".."] -> {:error, :bad_name}
      String.contains?(name, ["/", "\\", <<0>>]) -> {:error, :bad_name}
      byte_size(name) > @max_name -> {:error, :bad_name}
      not String.valid?(name) -> {:error, :bad_name}
      true -> {:ok, name}
    end
  end

  def safe_name(_name), do: {:error, :bad_name}

  defp safe_names(names) when is_list(names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case safe_name(name) do
        {:ok, name} -> {:cont, {:ok, acc ++ [name]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp safe_names(_names), do: {:error, :bad_name}

  defp fetch_place(key) do
    case place(key) do
      nil -> {:error, :unknown_root}
      place -> {:ok, place}
    end
  end

  # -- reading ----------------------------------------------------------------

  @doc """
  What is in a directory: directories first, then names, case-insensitively.

  Directories first because they are the thing being navigated and the panel
  shows twelve rows at a time. Dotfiles are included -- see the moduledoc.
  """
  @spec list(location()) :: {:ok, [entry()]} | {:error, reason()}
  def list(location) do
    with {:ok, dir} <- resolve(location),
         {:ok, names} <- File.ls(dir) do
      entries =
        names
        |> Enum.map(&describe(dir, &1))
        |> Enum.sort_by(&{&1.type != :directory, String.downcase(&1.name)})

      {:ok, entries}
    end
  end

  @doc """
  One entry, without listing its parent.
  """
  @spec stat(location()) :: {:ok, entry()} | {:error, reason()}
  def stat(location) do
    with {:ok, path} <- resolve(location),
         {:ok, name} <- basename(location) do
      case File.lstat(path) do
        {:ok, _info} -> {:ok, describe(Path.dirname(path), name)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # lstat for what the entry *is*, stat for what it leads to. Both, because on
  # this device the difference is the whole story in two directories: the core
  # directory is nothing but symlinks, and `bundles/retroarch/current` is one.
  defp describe(dir, name) do
    path = Path.join(dir, name)

    link =
      case :file.read_link(path) do
        {:ok, target} -> List.to_string(target)
        _error -> nil
      end

    {type, size} =
      case File.stat(path) do
        {:ok, %File.Stat{type: :regular, size: size}} -> {:regular, size}
        {:ok, %File.Stat{type: type}} -> {type, nil}
        {:error, _reason} -> {:missing, nil}
      end

    %{name: name, type: type, size: size, link: link, broken?: type == :missing}
  end

  @doc """
  Free space on the filesystem holding a location, or `nil`.

  Per location, not per device, and that is the point. The roots span more
  than one filesystem -- the writable f2fs partition and, when the card is in,
  the exFAT games card -- so one global number would be wrong for whichever
  one it was not measuring. `/` is a read-only squashfs at 100% full and is
  not reachable from here at all, which is the number it would be most
  misleading to show.

  Read from `df`, because OTP has no statvfs and busybox's `df` is in the
  image. `nil` rather than a guess when the output does not parse.
  """
  @spec space(location() | String.t()) ::
          %{device: String.t(), total: non_neg_integer(), free: non_neg_integer()} | nil
  def space(%{} = location) do
    case resolve(location) do
      {:ok, path} -> space(path)
      {:error, _reason} -> nil
    end
  end

  def space(path) when is_binary(path) do
    {out, 0} = System.cmd("df", ["-k", path], stderr_to_stdout: true)

    # Positional from the front, matching the parse that is already proven
    # against this image's busybox df. Anything unexpected falls into the
    # rescue below and becomes nil.
    [device, total, used, free | _rest] =
      out
      |> String.split("\n", trim: true)
      |> List.last()
      |> String.split()

    %{
      device: device,
      total: kb(total),
      used: kb(used),
      free: kb(free)
    }
  rescue
    _error -> nil
  end

  defp kb(blocks), do: String.to_integer(blocks) * 1024

  # -- writing ----------------------------------------------------------------

  @doc """
  Copy a regular file into a directory, keeping its name.

  Fsynced before the rename; see the moduledoc. Refuses a symlink source, a
  directory, an existing destination, and a destination filesystem with less
  free space than the file needs.

  `:sync` is the one seam this module has for the tests. Durability cannot be
  asserted by looking at a file afterwards -- an unsynced file is there too,
  right up until the power goes -- so the test passes a function that records
  that the sync happened, and that it happened on a handle that was still
  open.
  """
  @spec copy(location(), location(), keyword()) :: :ok | {:error, reason()}
  def copy(source, dest_dir, opts \\ []) do
    with {:ok, from} <- resolve(source),
         {:ok, name} <- basename(source),
         {:ok, dir} <- resolve(dest_dir),
         :ok <- require_no_link(from),
         {:ok, size} <- require_regular(from),
         :ok <- require_directory(dir),
         to = Path.join(dir, name),
         :ok <- require_different(from, to),
         :ok <- require_absent(to),
         :ok <- require_room(dir, size) do
      case stream_copy(from, to, opts) do
        :ok ->
          Logger.info("[files] copied #{from} -> #{to} (#{size} bytes)")
          :ok

        {:error, reason} ->
          Logger.warning("[files] copy #{from} -> #{to} failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Move an entry into a directory, keeping its name.

  A rename when the destination is on the same filesystem, which is the usual
  case and is atomic and instant whatever the file's size. Across filesystems
  the kernel answers `:exdev` and this falls back to a copy -- fsynced -- and
  then removes the source, which is the only way a ROM gets from the internal
  card onto the games card.

  A directory can be moved only by rename. Across filesystems it is refused,
  because that is a recursive copy; see the moduledoc.

  `:rename` is a test seam, and it exists for one reason: a test cannot mount
  a second filesystem, so there is no other way to reach the `:exdev` path --
  the path that has to fsync -- from the host.
  """
  @spec move(location(), location(), keyword()) :: :ok | {:error, reason()}
  def move(source, dest_dir, opts \\ []) do
    with {:ok, from} <- resolve(source),
         {:ok, name} <- basename(source),
         {:ok, dir} <- resolve(dest_dir),
         :ok <- require_exists(from),
         :ok <- require_directory(dir),
         to = Path.join(dir, name),
         :ok <- require_different(from, to),
         :ok <- require_absent(to) do
      rename = Keyword.get(opts, :rename, &File.rename/2)

      case rename.(from, to) do
        :ok ->
          Logger.info("[files] moved #{from} -> #{to}")
          :ok

        {:error, :exdev} ->
          across(source, from, to, opts)

        {:error, reason} ->
          Logger.warning("[files] move #{from} -> #{to} failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  # Same filesystem was not on offer, so this is a copy and a delete. The copy
  # is the fsynced one; the source is removed only after the destination is
  # renamed into place, so an interruption leaves two files rather than none.
  defp across(source, from, to, opts) do
    with :ok <- require_no_link(from),
         {:ok, size} <- require_regular(from),
         :ok <- require_room(Path.dirname(to), size),
         :ok <- stream_copy(from, to, opts),
         :ok <- delete(source) do
      Logger.info("[files] moved #{from} -> #{to} across filesystems (#{size} bytes)")
      :ok
    else
      {:error, :eisdir} ->
        {:error, :exdev}

      {:error, reason} ->
        Logger.warning("[files] move #{from} -> #{to} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Rename an entry in place.

  The new name goes through `safe_name/1` like every other name, so a rename
  cannot be a move and cannot be a traversal: it stays in the directory it was
  already in.
  """
  @spec rename(location(), String.t(), keyword()) :: :ok | {:error, reason()}
  def rename(source, new_name, opts \\ []) do
    with {:ok, _old} <- basename(source),
         {:ok, new_name} <- safe_name(new_name),
         {:ok, from} <- resolve(source),
         parent = ascend(source),
         {:ok, dir} <- resolve(parent),
         to = Path.join(dir, new_name),
         :ok <- require_exists(from),
         :ok <- require_different(from, to),
         :ok <- require_absent(to) do
      rename = Keyword.get(opts, :rename, &File.rename/2)

      case rename.(from, to) do
        :ok ->
          Logger.info("[files] renamed #{from} -> #{new_name}")
          :ok

        {:error, reason} ->
          Logger.warning("[files] rename #{from} failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Delete one entry.

  A regular file, a symlink -- the link itself, never its target -- or an
  empty directory. A directory with anything in it is `{:error, :not_empty}`:
  a recursive delete driven by a D-pad, on the partition that holds the
  bundles and the saves, is not a thing this device needs.

  There is no confirmation here on purpose. The confirmation belongs to the
  screen that has the name on it; a module that asked twice would be asking
  the caller, which is not who is about to lose a file.
  """
  @spec delete(location()) :: :ok | {:error, reason()}
  def delete(location) do
    with {:ok, path} <- resolve(location),
         {:ok, _name} <- basename(location) do
      case File.lstat(path) do
        {:ok, %File.Stat{type: :symlink}} -> remove(path, &File.rm/1, "link")
        {:ok, %File.Stat{type: :regular}} -> remove(path, &File.rm/1, "file")
        {:ok, %File.Stat{type: :directory}} -> remove(path, &rmdir/1, "directory")
        {:ok, %File.Stat{type: type}} -> {:error, {:unsupported, type}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp remove(path, remover, what) do
    case remover.(path) do
      :ok ->
        Logger.info("[files] deleted #{what} #{path}")
        :ok

      {:error, reason} ->
        Logger.warning("[files] delete #{path} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Linux says :enotempty and some systems say :eexist. One name for it, so
  # the panel can say "not empty" without knowing which kernel it is on.
  defp rmdir(path) do
    case File.rmdir(path) do
      {:error, reason} when reason in [:eexist, :enotempty] -> {:error, :not_empty}
      other -> other
    end
  end

  # -- the copy itself --------------------------------------------------------

  defp stream_copy(from, to, opts) do
    sync = Keyword.get(opts, :sync, &:file.sync/1)
    part = to <> ".part"
    File.rm(part)

    case File.open(from, [:read, :binary, :raw]) do
      {:ok, src} ->
        result = write_part(src, part, sync)
        File.close(src)
        finish(result, part, to)

      {:error, reason} ->
        {:error, {:open, reason}}
    end
  end

  defp write_part(src, part, sync) do
    case File.open(part, [:write, :binary, :raw]) do
      {:ok, dst} ->
        result = pump(src, dst)

        # The sync goes here, before the close and only on a complete copy:
        # syncing a handle that has already been closed is not a sync, and
        # syncing a truncated file makes the truncation durable.
        result = if result == :ok, do: sync.(dst), else: result

        File.close(dst)
        result

      {:error, reason} ->
        {:error, {:open, reason}}
    end
  end

  defp pump(src, dst) do
    case :file.read(src, @chunk) do
      {:ok, data} ->
        # :file.write, not IO.binwrite: the handle is :raw, so there is no IO
        # server behind it for the IO functions to talk to.
        case :file.write(dst, data) do
          :ok -> pump(src, dst)
          {:error, reason} -> {:error, {:write, reason}}
        end

      :eof ->
        :ok

      {:error, reason} ->
        {:error, {:read, reason}}
    end
  end

  defp finish(:ok, part, to) do
    case File.rename(part, to) do
      :ok ->
        :ok

      {:error, reason} ->
        File.rm(part)
        {:error, {:rename, reason}}
    end
  end

  defp finish({:error, reason}, part, _to) do
    File.rm(part)
    {:error, reason}
  end

  # -- checks -----------------------------------------------------------------

  defp require_regular(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} -> {:ok, size}
      {:ok, %File.Stat{type: :directory}} -> {:error, :eisdir}
      {:ok, %File.Stat{type: :symlink}} -> {:error, :is_symlink}
      {:ok, %File.Stat{}} -> {:error, :enotsup}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_no_link(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> {:error, :is_symlink}
      {:ok, %File.Stat{}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_exists(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_directory(path) do
    if File.dir?(path), do: :ok, else: {:error, :enotdir}
  end

  defp require_absent(path) do
    # lstat, so a broken symlink counts as present: renaming onto one would
    # remove it, and that is a delete nobody asked for.
    case File.lstat(path) do
      {:ok, %File.Stat{}} -> {:error, :eexist}
      {:error, _reason} -> :ok
    end
  end

  defp require_different(from, to) do
    if from == to, do: {:error, :same_path}, else: :ok
  end

  # Checked before the first byte, not discovered after 4 GB. Skipped when df
  # says nothing useful, because refusing every copy on a board where df
  # surprised us would be worse than the risk of running out.
  defp require_room(dir, size) do
    case space(dir) do
      %{free: free} when free < size -> {:error, :enospc}
      _other -> :ok
    end
  end
end
