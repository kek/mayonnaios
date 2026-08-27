defmodule MayonnaiOS.Scene.StatusBar do
  @moduledoc """
  The strip across the top of every screen: battery, WiFi, clock.

  One component, mounted by every scene in this firmware, drawing readings
  from `MayonnaiOS.Status`. It is a `Scenic.Component`, so each scene adds one
  line to its graph and gets its own instance -- and because a component is a
  scene in its own right, the bar repaints on its own clock without the screen
  underneath it being rebuilt. The launcher menu still redraws only when
  somebody presses something.

  ## "Every app" means every Scenic scene, and RetroArch is not one

  The five screens in this firmware are the launcher, diagnostics, the file
  manager, the Bluetooth devices app and the Bluetooth controller app. All
  five mount this. What the launcher *launches* is a different matter:
  RetroArch and kmscube are external processes that open the display and hold
  it until they exit. Nothing in this VM is drawing while they run, there is
  no compositor on this device, and a bar over a game is not something this
  code could provide by trying harder. So while a program owns the screen
  there is no status bar, and that is a property of the arrangement rather
  than a gap to be filled later.

  "There is no status bar" has to mean no *graph push*, not merely no visible
  bar, and that is what `MayonnaiOS.Panel` is for. This component is the one
  thing on the panel that changes without anybody pressing anything -- the
  clock turns over, the battery percent moves, a reading goes quiet -- so it
  is also the one thing that would, once a minute, hand Scenic a changed
  graph and have it write `/dev/fb0` underneath a running game. On this SoC
  that write hangs the board. It cost a device hang on the first SNES game
  launched after the bar shipped: loading the core survived only because it
  happened inside the same clock minute.

  Pausing `MayonnaiOS.Status` would not have been the fix. A reading going
  stale during a game is itself a change -- to the `no reading` form -- and
  the `:tick` below would draw it. The thing that must not happen is the
  push.

  ## Nothing is drawn from a reading that has gone quiet

  `MayonnaiOS.Status` stamps every reading with the time it was taken. Once a
  reading is older than `@stale_ms` -- six seconds, three missed polls -- this
  stops drawing the number and says `no reading` instead.

  That is the point of the whole arrangement rather than a nicety. This
  project's characteristic failure is a plausible value that never moves: an
  `hci0` that existed while Bluetooth was dead, CI green on an image with no
  GPU, a battery percentage that looked right and was a memory. A bar that
  kept drawing 87% after the reader wedged would be the same bug in a more
  prominent place, and it would be believed, because it is next to a clock
  that is still ticking.

  So the two are separated deliberately: the clock is read here, at the
  moment of drawing, and cannot be stale in this sense; the battery and the
  WiFi state come from another process and are drawn only while they are
  fresh. If the panel itself freezes, everything on it is stale and nothing
  in here can say so -- that is what the heartbeat LED is for.

  ## The clock says UTC because the clock is UTC

  There is no timezone database in this image -- no `tzdata`, nothing for
  `DateTime.shift_zone/2` to resolve -- and the RTC keeps UTC, which the
  kernel copies into system time at boot (`hctosys`, and the diagnostics
  screen has the row that proves it). So the bar shows UTC and says so. A bar
  showing `15:42` with no qualifier, an hour or two off whoever is holding it,
  is worse than one that admits which clock it is reading.

  A year before 2020 is drawn as `clock unset` rather than as a time, because
  that is what an RTC that lost its charge looks like, and 1970 rendered as
  `01:34` is a confident lie.
  """

  use Scenic.Component, has_children: false

  alias MayonnaiOS.{Panel, Power, Status, Theme}
  alias Scenic.Graph

  import Scenic.Primitives

  @width 640

  # The height of the strip. Every scene reserves it and takes the number
  # from `height/0`, so there is one place to change it and a test that
  # asserts nothing draws inside it.
  @height 30

  # The current theme's chrome, read fresh every draw -- see
  # `MayonnaiOS.Theme` and `MayonnaiOS.Scene.Home` for why these are
  # functions and not module attributes. The background is two shades
  # lighter than the current theme's screen background so the strip stays
  # visible as a strip whichever theme is picked.
  defp font, do: Theme.current().font
  defp bar_bg, do: Theme.current().bar_bg
  defp title, do: Theme.current().title
  defp label, do: Theme.current().label
  defp pass, do: Theme.current().pass
  defp fail, do: Theme.current().fail
  defp wait, do: Theme.current().wait
  defp dim, do: Theme.current().dim

  # A reading older than this is not drawn. Three missed polls of
  # `MayonnaiOS.Status`, which polls every two seconds: long enough that a
  # busy moment does not make the panel flicker into "no reading", short
  # enough that a wedged reader is visible before anyone acts on the number.
  @stale_ms 6_000

  # Once a second, for the clock and for noticing that the reader has gone
  # quiet. Most ticks change nothing, and `render/1` compares what it is about
  # to draw with what it drew and pushes nothing when they match -- so the
  # steady state is one graph push a minute, when the minute changes.
  @tick_ms 1_000

  # Laid out from the right edge leftwards, because the right edge is the
  # thing that has to stay put: the fields grow and shrink with their own
  # text, and a fixed left origin would let a long word walk off the panel.
  @right 626
  @gap 16
  @baseline 20
  @font 13
  # 12 is the smallest size anything on this device draws at; the word "wifi"
  # is context rather than a reading, so it gets the floor and not less.
  @small 12

  @doc "The height of the strip. Scenes leave this much room and draw below it."
  @spec height() :: pos_integer()
  def height, do: @height

  @doc """
  Add the bar to a scene's graph.

  Every scene calls this from whatever builds its background, so a screen
  cannot exist without it.
  """
  @spec mount(Graph.t(), keyword()) :: Graph.t()
  def mount(graph, opts \\ []) do
    add_to_graph(graph, Map.new(opts), id: :status_bar)
  end

  @impl Scenic.Component
  def validate(nil), do: {:ok, %{}}
  def validate(opts) when is_map(opts), do: {:ok, opts}
  def validate(opts) when is_list(opts), do: {:ok, Map.new(opts)}

  def validate(other) do
    {:error, "#{inspect(other)} is not status bar options; pass nil or a map"}
  end

  @impl Scenic.Scene
  def init(scene, param, _opts) do
    server = server(param)

    # A cast, so a reader that is missing or wedged cannot stop the root scene
    # from starting. See `MayonnaiOS.Status.subscribe/1`.
    Status.subscribe(server)
    :timer.send_interval(@tick_ms, :tick)

    {:ok, scene |> assign(server: server, reading: nil, drawn: nil) |> render()}
  end

  @impl GenServer
  def handle_info({:mayonnaios_status, reading}, scene) do
    {:noreply, scene |> assign(reading: reading) |> render()}
  end

  def handle_info(:tick, scene) do
    knock(scene)
    {:noreply, render(scene)}
  end

  def handle_info(_message, scene), do: {:noreply, scene}

  defp server(%{server: server}), do: server
  defp server(_param), do: Status

  # While there is nothing fresh to draw, ask again -- once a second, as a
  # cast, which costs a message.
  #
  # A subscription is held by the reader, so it is lost whenever the reader is
  # lost: a `MayonnaiOS.Status` that crashed and was restarted by the
  # supervisor has no subscribers, and the scenes mounted before it would
  # otherwise say "no reading" until the launcher next tore them down. Knocking
  # while stale also covers the reverse ordering at boot, a bar mounted before
  # the reader exists. It stops as soon as a reading arrives, so a healthy
  # device sends none of these.
  defp knock(scene) do
    if stale?(scene.assigns.reading) do
      Status.subscribe(scene.assigns.server)
    end

    :ok
  end

  # The same freshness rule the drawing uses, so there is no way for the bar to
  # be knocking while it draws numbers or drawing dashes while it sits quiet.
  defp stale?(reading) do
    now = System.monotonic_time(:millisecond)
    Enum.any?([:battery, :wifi], &(fresh(reading, &1, now) == :stale))
  end

  # Two reasons not to draw, and they are different reasons.
  #
  # Nothing changed: the ordinary case, once a second, and the whole point of
  # keeping `drawn` -- a graph push that would produce the same pixels is a
  # framebuffer write for nothing.
  #
  # The panel is not ours: an external program owns the display, and a write
  # into it hangs the board. `MayonnaiOS.Panel.draw/2` is the one place that
  # knows, and it leaves `drawn` alone, so this bar still has a difference to
  # notice if it outlives the hold.
  #
  # The order matters only for cost. Asking `Panel` is a `:persistent_term`
  # read, so it is cheap enough to ask before building anything, and asking
  # first means a bar under a running game does no work at all.
  defp render(scene) do
    fields = fields(scene.assigns.reading)

    if fields == scene.assigns.drawn do
      scene
    else
      scene |> assign(drawn: fields) |> Panel.draw(graph(fields))
    end
  end

  # -- what the bar says ------------------------------------------------------

  @doc """
  What the bar would draw for a reading, as words.

  Public because it is the tested surface, and because the words are the
  interesting part: whether a stale battery reads `no reading` rather than
  `87%` is a property worth asserting without a framebuffer.

  Options are for the tests: `:now` is a monotonic millisecond reading to
  measure the reading's age against, `:utc` is the `DateTime` to draw as the
  clock.
  """
  @spec fields(Status.reading() | nil, keyword()) :: map()
  def fields(reading, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, fn -> System.monotonic_time(:millisecond) end)
    utc = Keyword.get_lazy(opts, :utc, fn -> DateTime.utc_now() end)

    %{
      battery: battery(fresh(reading, :battery, now)),
      wifi: wifi(fresh(reading, :wifi, now)),
      clock: clock(utc)
    }
  end

  # A source is only itself while it is fresh. Anything else -- never heard
  # from, heard from too long ago -- collapses to :stale here, once, so that
  # no drawing code further down can accidentally reach a remembered value.
  defp fresh(nil, _key, _now), do: :stale

  defp fresh(reading, key, now) do
    case Map.get(reading, key) do
      %{at: at} = source when is_integer(at) ->
        if now - at > @stale_ms, do: :stale, else: source

      _missing ->
        :stale
    end
  end

  defp battery(:stale), do: %{percent: "--", level: nil, word: "no reading", colour: fail()}

  defp battery(%{error: reason}) when not is_nil(reason) do
    %{percent: "--", level: nil, word: "no battery", colour: wait()}
  end

  defp battery(%{value: values}) do
    {word, colour} = state_word(Power.state(values))

    %{
      percent: percent(values[:capacity]),
      level: level(values[:capacity]),
      word: word,
      colour: colour
    }
  end

  defp percent(nil), do: "--"
  defp percent(capacity), do: "#{capacity}%"

  defp level(capacity) when is_integer(capacity), do: min(max(capacity, 0), 100)
  defp level(_capacity), do: nil

  # The state is always shown, including the boring one. "on battery" that
  # never becomes "charging" while the cable is in is a fault someone can see;
  # a bar that only marks charging leaves the same fault looking like normal.
  defp state_word(:charging), do: {"charging", pass()}
  defp state_word(:discharging), do: {"on battery", label()}
  defp state_word(:full), do: {"full", pass()}
  defp state_word(:not_charging), do: {"not charging", wait()}
  defp state_word(:unknown), do: {"no state", wait()}

  defp wifi(:stale), do: %{word: "no reading", colour: fail()}
  defp wifi(%{error: :not_managed}), do: %{word: "not managed", colour: dim()}
  defp wifi(%{error: :no_interface}), do: %{word: "no wlan0", colour: wait()}
  defp wifi(%{error: reason}) when not is_nil(reason), do: %{word: "unavailable", colour: wait()}
  defp wifi(%{value: :internet}), do: %{word: "internet", colour: pass()}
  defp wifi(%{value: :lan}), do: %{word: "lan only", colour: wait()}
  defp wifi(%{value: :disconnected}), do: %{word: "no network", colour: fail()}
  defp wifi(%{value: other}), do: %{word: clip(to_string(other), 12), colour: wait()}

  # An RTC that lost its charge comes up in 1970, and 1970 drawn as a time is
  # a clock that is confidently wrong. 2020 rather than the build year because
  # any plausible date is fine here; the check is for a clock that was never
  # set at all.
  defp clock(%DateTime{year: year}) when year < 2020, do: %{text: "clock unset", colour: wait()}

  defp clock(utc) do
    %{text: "#{pad(utc.hour)}:#{pad(utc.minute)} UTC", colour: title()}
  end

  defp pad(n), do: String.pad_leading(to_string(n), 2, "0")

  defp clip(text, limit) do
    if String.length(text) > limit, do: String.slice(text, 0, limit - 1) <> "…", else: text
  end

  # -- drawing ----------------------------------------------------------------

  @doc """
  Build the bar's graph for a set of fields.

  Takes the output of `fields/2` so that the words and the drawing can be
  tested apart: what the bar says is arithmetic on a reading, where it says it
  is arithmetic on font metrics.
  """
  @spec graph(map()) :: Graph.t()
  def graph(fields) do
    graph =
      Graph.build(font: font(), font_size: @font)
      |> rect({@width, @height}, fill: {:color, bar_bg()})
      # A one-pixel rule rather than a border, and in the dim grey the footers
      # use, so the strip is separated from the screen without competing with
      # the blue rule each scene draws under its own title.
      |> rect({@width, 1}, fill: {:color, dim()}, translate: {0, @height - 1})

    {graph, left} = clock_field(graph, fields.clock, @right)
    {graph, left} = wifi_field(graph, fields.wifi, left - @gap)
    {graph, _left} = battery_field(graph, fields.battery, left - @gap)

    graph
  end

  defp clock_field(graph, clock, right) do
    x = right - width(clock.text, @font)

    {text(graph, clock.text,
       font_size: @font,
       fill: {:color, clock.colour},
       translate: {x, @baseline}
     ), x}
  end

  # The word "wifi" in front of the state, small and grey. No signal bars:
  # what VintageNet publishes here is whether the interface has a network and
  # whether that network reaches the internet, not a signal strength, and
  # three bars mean strength to everyone who has ever seen a phone.
  defp wifi_field(graph, wifi, right) do
    label_w = width("wifi", @small)
    word_w = width(wifi.word, @font)
    x = right - (label_w + 5 + word_w)

    graph =
      graph
      |> text("wifi", font_size: @small, fill: {:color, dim()}, translate: {x, @baseline})
      |> text(wifi.word,
        font_size: @font,
        fill: {:color, wifi.colour},
        translate: {x + label_w + 5, @baseline}
      )

    {graph, x}
  end

  defp battery_field(graph, battery, right) do
    percent_w = width(battery.percent, @font)
    word_w = width(battery.word, @font)
    icon_w = 25
    x = right - (icon_w + 6 + percent_w + 6 + word_w)

    graph =
      graph
      |> icon(x, battery)
      |> text(battery.percent,
        font_size: @font,
        fill: {:color, title()},
        translate: {x + icon_w + 6, @baseline}
      )
      |> text(battery.word,
        font_size: @font,
        fill: {:color, battery.colour},
        translate: {x + icon_w + 6 + percent_w + 6, @baseline}
      )

    {graph, x}
  end

  # The outline is always drawn; the fill only when there is a level to draw.
  # An empty outline is the honest picture of "no reading", and it is a
  # different picture from a flat battery, which draws a red sliver.
  defp icon(graph, x, %{level: nil} = battery) do
    body(graph, x, battery.colour)
  end

  defp icon(graph, x, %{level: level}) do
    graph
    |> body(x, label())
    |> rect({max(round(18 * level / 100), 1), 9},
      fill: {:color, level_colour(level)},
      translate: {x + 2, 10}
    )
  end

  defp body(graph, x, colour) do
    graph
    |> rect({22, 13}, stroke: {1, colour}, translate: {x, 8})
    |> rect({3, 5}, fill: {:color, colour}, translate: {x + 22, 12})
  end

  # Colour by charge, not by whether it is charging: a battery at 8% is worth
  # a red bar whether or not the cable is in, and the word next to it already
  # says which.
  defp level_colour(level) when level < 15, do: fail()
  defp level_colour(level) when level < 40, do: wait()
  defp level_colour(_level), do: pass()

  # Measured rather than estimated, using the same metrics Scenic's own
  # components use, because the layout runs right to left and an estimate
  # that is 10% short puts two fields on top of each other.
  # `Theme.width/3` measures in the current theme's font instead of a
  # hardcoded `:roboto`, and still falls back to an estimate for a host
  # with no asset library compiled -- a wrong-looking bar in a test is
  # better than a scene that cannot build a graph.
  defp width(text, size) do
    Theme.width(text, size, font())
  end
end
