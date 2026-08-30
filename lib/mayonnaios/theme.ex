defmodule MayonnaiOS.Theme do
  @moduledoc """
  A theme is a font pairing plus a colour palette. This module is the one
  place both live, so a scene draws in "the current theme's colours" rather
  than in eight module attributes it happens to share with six other files.

  ## Why a struct and not just a map of colours

  Every scene under `MayonnaiOS.Scene` used to carry its own copy of the same
  eight-odd `{r, g, b}` constants (`@bg`, `@title`, `@head`, `@label`, `@pass`,
  `@fail`, `@wait`, `@dim`, sometimes `@row_bg`) as module attributes --
  correct, because Scenic has no theme concept of its own, but it meant
  "add a theme" was "edit N files identically." A struct gives every scene
  the same field names to reach for, and gives this module one place to add
  a theme rather than N.

  Semantic colours -- `pass`, `fail`, `wait` -- are deliberately the *same*
  green/red/amber across every theme here. A red "fail" that stopped reading
  as alarming because a theme tinted it purple would be a worse UI for the
  sake of a matching palette, so only the chrome (`bg`, `title`, `head`,
  `label`, `dim`, `row_bg`, `bar_bg`) varies by theme.

  ## Why a persistent_term and not process state

  The same reasoning as `MayonnaiOS.Panel`: a scene's `graph/2` (or
  `graph/3`) is a plain function called fresh on every redraw, by whichever
  process happens to be running that scene at the time -- and
  `Scenic.ViewPort.set_root/3` replaces that process outright on every scene
  switch. A theme selection kept in `GenServer` state would need to be
  threaded through every scene's `init/3`, and would still go stale the
  moment a scene restarts. A `:persistent_term` is a pointer dereference any
  of them can make, from `graph/2`, with no process and no message -- and
  writes here are rarer still than `Panel`'s: one per menu selection, not one
  per launch.

  ## What picking a theme in the System menu actually does

  `MayonnaiOS.Launcher`'s `:cycle_theme` action (see `browser.ex`'s System
  column) calls `cycle/0` and then repaints the home scene. `cycle/0` writes
  the next theme's name to the persistent term; the repaint tears down and
  rebuilds `Scene.Home`, whose `graph/3` reads `current/0` fresh. Nothing
  before this module needs to know a theme changed -- the same "it is read
  at the moment of drawing" property `MayonnaiOS.Scene.StatusBar` relies on
  for the clock.

  ## Scope: two scenes, not the whole UI

  Only `Scene.Home` (the launcher/column browser) and `Scene.StatusBar` (the
  strip every scene mounts, so it has to match whichever of them is showing)
  read this module today. `Scene.Controller`, `Scene.Diagnostics`,
  `Scene.Pairing`, `Scene.Pickle` and `Scene.Top` still carry their own copy
  of the *default* palette's numbers and Scenic's stock `:roboto` --
  unchanged in behaviour, just not yet plumbed through. Moving them over is
  the same mechanical edit repeated four more times, not a design problem;
  it was left out here to keep this change to the two scenes the launcher
  and browser task actually asked for.
  """

  alias Scenic.Assets.Static

  @type colour :: {0..255, 0..255, 0..255}
  @type name :: :default | :c64 | :synthwave

  @type t :: %MayonnaiOS.Theme{
          name: name(),
          font: atom(),
          title_font: atom(),
          bg: colour(),
          bar_bg: colour(),
          title: colour(),
          head: colour(),
          label: colour(),
          pass: colour(),
          fail: colour(),
          wait: colour(),
          dim: colour(),
          row_bg: colour()
        }

  defstruct [
    :name,
    :font,
    :title_font,
    :bg,
    :bar_bg,
    :title,
    :head,
    :label,
    :pass,
    :fail,
    :wait,
    :dim,
    :row_bg
  ]

  # Semantic colours, shared by every theme. See the moduledoc: these mean
  # something (safe, dangerous, wait) and a theme that recoloured them would
  # be recolouring the meaning, not the chrome.
  @pass {120, 220, 150}
  @fail {245, 110, 120}
  @wait {235, 190, 90}

  # A function rather than a module attribute: building a literal of this
  # module's own struct is only legal in a function body here, not in an
  # attribute -- the struct is not yet registered while attributes compile.
  defp themes do
    %{
      # The palette this firmware has always drawn in, set in Pixel Operator/
      # press_start_2p in place of Scenic's stock roboto/roboto_mono. Pixel
      # Operator HB replaces DotGothic16 as the body face because it reads
      # bigger on-device while keeping enough compact pixel width for the
      # launcher.
      default: %MayonnaiOS.Theme{
        name: :default,
        font: :pixel_operator,
        title_font: :press_start_2p,
        bg: {12, 14, 22},
        bar_bg: {20, 25, 38},
        title: {235, 238, 245},
        head: {90, 170, 255},
        label: {150, 165, 195},
        pass: @pass,
        fail: @fail,
        wait: @wait,
        dim: {110, 125, 155},
        row_bg: {26, 34, 52}
      },

      # Commodore 64 boot screen: the mid blue border/background and the
      # lighter blue-white text, nothing else on the palette.
      c64: %MayonnaiOS.Theme{
        name: :c64,
        font: :pixel_operator,
        title_font: :press_start_2p,
        bg: {53, 40, 176},
        bar_bg: {40, 30, 145},
        title: {173, 168, 255},
        head: {130, 170, 255},
        label: {154, 150, 220},
        pass: @pass,
        fail: @fail,
        wait: @wait,
        dim: {100, 95, 165},
        row_bg: {70, 58, 200}
      },

      # Dark purple night, neon pink chrome -- the two colours a synthwave
      # cover always reaches for, kept off the semantic colours for the same
      # reason c64's blues are.
      synthwave: %MayonnaiOS.Theme{
        name: :synthwave,
        font: :pixel_operator,
        title_font: :press_start_2p,
        bg: {22, 8, 38},
        bar_bg: {32, 12, 52},
        title: {255, 240, 250},
        head: {255, 70, 180},
        label: {200, 150, 220},
        pass: @pass,
        fail: @fail,
        wait: @wait,
        dim: {120, 80, 145},
        row_bg: {45, 18, 68}
      }
    }
  end

  # The order `cycle/0` advances through and the System menu lists in.
  @order [:default, :c64, :synthwave]

  @key {__MODULE__, :name}

  @doc "The built-in theme names, in menu/cycle order."
  @spec names() :: [name()]
  def names, do: @order

  @doc "The default theme -- what a fresh boot draws before anyone picks one."
  @spec default() :: t()
  def default, do: Map.fetch!(themes(), :default)

  @doc "Look up a built-in theme by name."
  @spec by_name(name()) :: {:ok, t()} | :error
  def by_name(name), do: Map.fetch(themes(), name)

  @doc """
  The theme in effect right now: whatever `set/1` or `cycle/0` last chose,
  falling back to `config :mayonnaios, :theme` (for boards that want a
  different default baked in) and then to `:default`.
  """
  @spec current() :: t()
  def current do
    name = :persistent_term.get(@key, configured_default())

    case by_name(name) do
      {:ok, theme} -> theme
      :error -> default()
    end
  end

  defp configured_default, do: Application.get_env(:mayonnaios, :theme, :default)

  @doc """
  Select a theme by name. Returns `:error` and leaves the current theme in
  place for a name that is not one of `names/0`, so a typo in config cannot
  blank the screen.
  """
  @spec set(name()) :: :ok | :error
  def set(name) do
    case by_name(name) do
      {:ok, _theme} ->
        :persistent_term.put(@key, name)
        :ok

      :error ->
        :error
    end
  end

  @doc """
  Advance to the next built-in theme, in `names/0` order, wrapping around.
  Returns the name now in effect. This is what the System menu's Theme row
  calls.
  """
  @spec cycle() :: name()
  def cycle do
    current_index = Enum.find_index(@order, &(&1 == current().name)) || 0
    next = Enum.at(@order, rem(current_index + 1, length(@order)))
    set(next)
    next
  end

  @doc """
  Measure `text` set in the current theme's body font, in pixels, at
  `size`. The same measurement `Scene.StatusBar` needs to lay itself out
  right-to-left, freed from a hardcoded `:roboto`.
  """
  @spec width(String.t(), number()) :: number()
  def width(text, size), do: width(text, size, current().font)

  @spec width(String.t(), number(), atom()) :: number()
  def width(text, size, font) do
    case Static.meta(font) do
      {:ok, {Static.Font, metrics}} -> FontMetrics.width(text, size, metrics)
      _other -> String.length(text) * size * 0.55
    end
  end
end
