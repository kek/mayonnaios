defmodule MayonnaiOS.Panel do
  @moduledoc """
  Who owns the panel right now: this VM, or an external program.

  There is one framebuffer on this device and no compositor. When
  `MayonnaiOS.Launcher` starts RetroArch or kmscube, that process opens
  `/dev/dri/card0` and becomes DRM master; `/dev/fb0` is the same display
  through DRM's fbdev emulation (`sun4i-drmdrmfb`). Anything in this VM that
  writes the framebuffer while that program holds the display is writing into
  a device somebody else owns, and on this SoC that hangs the board -- not the
  Elixir process, the board, with the game still on screen and the buttons
  dead.

  So the handover needs a fact that more than one module can consult, and this
  is it: two functions and a term.

  ## Why this exists rather than a call to the launcher

  The launcher is the only thing that starts and reaps external programs, so
  it is the only thing that can know. But asking it -- `Launcher.running?()`
  from inside a scene's render -- is the wrong shape three times over. It
  makes a leaf component depend on the process that launches things; it is a
  `GenServer.call` on the path that draws the panel, into the one process that
  is also handling every button press; and the answer is a message round trip,
  so what comes back is what was true a moment ago.

  A `:persistent_term` is the opposite of all three. The read is a pointer
  dereference with no message and no process, the launcher is the only writer,
  and the write happens *before* `Port.open/2` -- so by the time the program
  can possibly have taken the display, every reader already sees the hold.
  Writes are rare, which is the condition `:persistent_term` asks for: one per
  launch and one per exit, not one per frame.

  ## Why it is a synchronous read and not a notification

  A subscription -- the launcher telling the scenes, each keeping a flag --
  cannot work here, and the reason is worth writing down because it is
  invisible from the outside.

  Scenic restarts a component when its parent scene pushes a graph. On the
  diagnostics screen, which pushes once a second, the status bar is a *new
  process every second* -- measured, in `test/panel_test.exs`, by watching the
  subscriber pid in `MayonnaiOS.Status` change on every refresh. A flag
  learned from a notification does not survive that: each new instance starts
  out knowing nothing, and `init/3` draws before any notification could
  arrive. Suppression has to be something a process one millisecond old can
  ask, which is what this is.

  ## What holds, and what does not

  Only a program launched as an external OS process -- a `path:` entry in
  `config :mayonnaios, :programs` -- takes the display. An *app* (`app:`,
  e.g. `MayonnaiOS.FileManager`, `MayonnaiOS.Pairing`,
  `MayonnaiOS.Controller`) is a Scenic scene in this VM: it draws through the
  same viewport as everything else and takes nothing away from it. Apps must
  therefore keep the bar ticking, and they never hold.

  Getting that distinction wrong is a bug in both directions: a hold that
  covers apps freezes the clock on the file manager, and a hold that misses a
  program hangs the device in a game. The launcher's one-at-a-time rule keeps
  the two apart -- it will not launch a program while an app is up, and an
  app's scene is replaced on the way out -- so no app scene is ever alive
  while this is held.

  ## Ownership is not the same question as which scene is showing

  The suppression is about who owns the panel, not about what is on it.
  Someone can press X during a game and sit on the diagnostics screen while
  kmscube runs: the scene is alive, its one-second refresh is running, and
  every one of those refreshes would be a write into the framebuffer of a
  program that owns the display. That is why scenes ask this module rather
  than asking whether they are the visible one.
  """

  alias Scenic.Scene

  @key {__MODULE__, :owner}

  @type owner :: :ui | {:program, String.t()}

  @doc """
  Record that an external program owns the panel.

  Called by the launcher immediately before it spawns the program, so that
  nothing can paint between the decision to launch and the program taking the
  display.
  """
  @spec hold(String.t()) :: :ok
  def hold(name) when is_binary(name) do
    :persistent_term.put(@key, {:program, name})
    :ok
  end

  @doc """
  Record that the panel is this VM's again.

  Called by the launcher when the program exits or is stopped -- and from its
  `init/1`, because a launcher that has just started has no program running,
  whatever a term left over from a previous incarnation says. That is the one
  thing that recovers a hold whose holder died: the hold lives in the VM
  rather than in a process, so nothing else would ever clear it.
  """
  @spec release() :: :ok
  def release do
    :persistent_term.erase(@key)
    :ok
  end

  @doc """
  Who owns the panel: `:ui`, or `{:program, name}`.

  The name is for logs and for the diagnostics screen; nothing decides
  anything on it.
  """
  @spec owner() :: owner()
  def owner, do: :persistent_term.get(@key, :ui)

  @doc """
  True while an external program owns the panel.
  """
  @spec held?() :: boolean()
  def held?, do: match?({:program, _name}, owner())

  @doc """
  `Scenic.Scene.push_graph/2`, unless an external program owns the panel.

  Every scene that draws on its own clock goes through this instead of
  `push_graph/2`, so there is one sentence in one place that says when this
  firmware may write the display.

  The scene is returned untouched when the panel is held -- untouched
  deliberately, including whatever the scene remembers about what it last
  drew. A suppressed push is not a push, so a scene that tracks its own
  drawn state (`MayonnaiOS.Scene.StatusBar` does) still has a difference to
  notice afterwards rather than a memory of a frame that never reached the
  panel.
  """
  @spec draw(Scene.t(), Scenic.Graph.t()) :: Scene.t()
  def draw(scene, graph) do
    if held?(), do: scene, else: Scene.push_graph(scene, graph)
  end
end
