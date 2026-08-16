defmodule ScenicRg40xxv.Programs do
  @moduledoc """
  The list of external programs the launcher offers, read from config.

  A pure module: no process, no state, no cache. Every call re-reads the
  application environment and re-stats the paths, which costs a handful of
  `File.exists?/1` calls per keypress and buys the property that matters --
  what the panel says is what the filesystem contains right now.

  ## Why config and not a scan of /usr/bin

  This is an appliance, so the device has to *name and order* what it offers.
  A directory scan cannot do that: `/usr/bin` on this image is full of things
  that would take the display and never give it back (anything that opens KMS
  and blocks), plus a hundred names no one would ever want on a menu. Config
  is also reviewable in the firmware source, which a scan is not.

  The cost is real and worth stating: adding a game needs a firmware rebuild.
  When that becomes annoying, `list/1` is the single seam -- a scan of a games
  directory appends its entries here, and nothing else in the launcher or the
  scene has to know it happened, because both already go through this module.

  ## Missing binaries are shown, not filtered

  An entry whose `path` is not in the image is returned with
  `installed?: false` rather than dropped. A dropped entry is invisible, and
  the failure it produces -- a menu that is quietly one line shorter than the
  config says -- looks exactly like a menu that is correct. Shown, it says
  "not installed" on the panel, which is a bug report anyone can read off the
  device without SSH.
  """

  @type program :: %{
          name: String.t(),
          path: String.t(),
          args: [String.t()],
          installed?: boolean()
        }

  @doc """
  The configured programs, normalized and stat'd.

  Pass `configured` to bypass the application environment; that is what the
  tests do, and it is the seam a future directory scan appends to.
  """
  @spec list([map() | keyword()] | nil) :: [program()]
  def list(configured \\ nil) do
    entries = configured || Application.get_env(:scenic_rg40xxv, :programs, [])
    Enum.map(entries, &normalize/1)
  end

  @doc """
  The program at `index`, or `nil` when nothing is configured.

  The index is taken modulo the list length rather than trusted. The cursor
  lives in the Launcher and the list is re-read on every use, so a config
  that lost an entry (or a firmware update that shortened it) would otherwise
  leave the cursor pointing past the end and make A do nothing at all.
  """
  @spec at([program()], integer()) :: program() | nil
  def at([], _index), do: nil
  def at(programs, index), do: Enum.at(programs, Integer.mod(index, length(programs)))

  @doc """
  Move the cursor by `delta`, wrapping at both ends.

  Wrapping rather than clamping because the D-pad is the only way to move:
  with six entries, reaching the last one from the first is one press up
  instead of five presses down.
  """
  @spec step([program()], integer(), integer()) :: non_neg_integer()
  def step([], _index, _delta), do: 0
  def step(programs, index, delta), do: Integer.mod(index + delta, length(programs))

  defp normalize(entry) when is_list(entry), do: entry |> Map.new() |> normalize()

  defp normalize(%{path: path} = entry) when is_binary(path) do
    %{
      name: Map.get(entry, :name) || Path.basename(path),
      path: path,
      args: Map.get(entry, :args, []),
      # Re-stat'd on every call, deliberately: firmware is immutable but the
      # data partition is not, and a cached "installed" would outlive the file.
      installed?: File.exists?(path)
    }
  end

  # An entry with no usable :path becomes a visible, unlaunchable row rather
  # than an exception.
  #
  # Not defensive padding. `list/0` is called from `Scene.Home.init/3` -- the
  # root scene, at boot -- and from `Launcher.move/2` on every D-pad press,
  # and neither has anywhere to put an error. Without this clause one mistyped
  # key (`%{name: "Doom", exec: "..."}` instead of `:path`) raises
  # FunctionClauseError inside the root scene, and the device boots to a blank
  # panel with nothing saying the fault is one line of config. Rendering the
  # bad entry says exactly where to look.
  defp normalize(entry) do
    %{name: "#{inspect(entry)} (no :path)", path: nil, args: [], installed?: false}
  end
end
