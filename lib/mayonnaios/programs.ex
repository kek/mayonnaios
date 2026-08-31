defmodule MayonnaiOS.Programs do
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

  ## Descriptions

  Optional description lines are presentation metadata. Config supplies explicit
  line breaks because the launcher preview pane is narrow.

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
          path: String.t() | nil,
          app: module() | {module(), term()} | nil,
          action: atom() | nil,
          args: [String.t()],
          category: atom() | nil,
          description: [String.t()] | nil,
          installed?: boolean()
        }

  @doc """
  The configured programs, normalized and stat'd.

  Pass `configured` to bypass the application environment; that is what the
  tests do, and it is the seam a directory scan appends to -- which is now
  not hypothetical: installed graphical pickles append their rows here, so
  they appear on the menu the moment they land, with no restart and no
  config change. Config first, pickles after, because the firmware's own
  entries are the stable part of the menu.
  """
  @spec list([map() | keyword()] | nil) :: [program()]
  def list(configured \\ nil) do
    entries = configured || Application.get_env(:mayonnaios, :programs, []) ++ pickles()
    Enum.map(entries, &normalize/1)
  end

  # The rows for installed pickles that asked for a face (the "ui"
  # capability). Re-read from disk on every call like everything else here,
  # and behind a rescue because the menu must survive anything the pickles
  # directory contains -- a broken manifest is Pickles' problem to report,
  # not the home screen's problem to crash on.
  defp pickles do
    MayonnaiOS.Pickles.program_rows()
  rescue
    _ -> []
  end

  defp normalize(entry) when is_list(entry), do: entry |> Map.new() |> normalize()

  # A pickle's row: the app module is shared and the argument names which
  # pickle, so the launcher's app plumbing works unchanged with one adapter
  # for all of them. Cannot be missing for the same reason a module cannot:
  # the row exists because the manifest was just read off the disk.
  defp normalize(%{app: {module, arg}} = entry) when is_atom(module) do
    %{
      name: Map.get(entry, :name) || inspect({module, arg}),
      path: nil,
      app: {module, arg},
      action: nil,
      args: [],
      # Which launcher column the row lands in, or nil to let
      # `MayonnaiOS.Browser` classify it. Carried through explicitly because
      # this function rebuilds the map rather than merging into it.
      category: Map.get(entry, :category),
      description: description(entry),
      needs_udev: false,
      installed?: true
    }
  end

  # An app is a module in this firmware rather than a binary on the disk:
  # `MayonnaiOS.Controller` is the one there is. It cannot be missing the way
  # a path can -- if the module were not in the release, nothing in this
  # application would have started -- so `installed?` is true and stays true.
  #
  # The distinction is worth keeping rather than pretending an app is a
  # program with an odd path. The launcher runs a program in another OS
  # process and takes the screen away from it; an app is `start/0` and
  # `stop/0` on a supervisor in this VM, and the two have nothing in common
  # but a row on a menu.
  # An action is a verb of the launcher's own rather than anything to run:
  # today only `:poweroff`. There is no path to stat and no module that could
  # be absent, so it is always "installed" -- a menu that can lose its off
  # switch to a config typo would fail exactly the way a dropped entry does,
  # invisibly. What the verb *does* is entirely `MayonnaiOS.Launcher`'s;
  # this module only carries the atom.
  defp normalize(%{action: action} = entry) when is_atom(action) and not is_nil(action) do
    %{
      name: Map.get(entry, :name) || Atom.to_string(action),
      path: nil,
      app: nil,
      action: action,
      args: [],
      category: Map.get(entry, :category),
      description: description(entry),
      needs_udev: false,
      installed?: true
    }
  end

  defp normalize(%{app: module} = entry) when is_atom(module) and not is_nil(module) do
    %{
      name: Map.get(entry, :name) || inspect(module),
      path: nil,
      app: module,
      action: nil,
      args: [],
      category: Map.get(entry, :category),
      description: description(entry),
      needs_udev: false,
      installed?: true
    }
  end

  defp normalize(%{path: path} = entry) when is_binary(path) do
    %{
      name: Map.get(entry, :name) || Path.basename(path),
      path: path,
      app: nil,
      action: nil,
      args: Map.get(entry, :args, []),
      category: Map.get(entry, :category),
      description: description(entry),
      # Programs that read input through udev; see MayonnaiOS.Udev. Carried
      # through explicitly because this function rebuilds the map rather than
      # merging into it, so anything not named here is dropped -- and a flag
      # that silently vanishes between config and launcher would look exactly
      # like the feature not working.
      needs_udev: Map.get(entry, :needs_udev, false),
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
    %{
      name: "#{inspect(entry)} (no :path)",
      path: nil,
      app: nil,
      action: nil,
      args: [],
      category: nil,
      description: nil,
      needs_udev: false,
      installed?: false
    }
  end

  defp description(%{description: lines}) when is_list(lines) and lines != [] do
    if Enum.all?(lines, &is_binary/1), do: lines, else: nil
  end

  defp description(_entry), do: nil
end
