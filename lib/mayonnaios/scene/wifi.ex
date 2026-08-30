defmodule MayonnaiOS.Scene.WiFi do
  @moduledoc """
  What the panel shows while `MayonnaiOS.WiFi.App` has the buttons.

  Draws `MayonnaiOS.WiFi.App.snapshot/0` and nothing else, told when to
  redraw by `App.watch/1` -- the same arrangement as `MayonnaiOS.Scene.Update`
  and for the same reason: `Scenic.ViewPort.set_root/3` terminates this scene
  on every repaint the launcher does, so nothing may be remembered here.

  Three pages, one per thing the app can be doing: the list, the passphrase
  wheel, and a sentence about a join that has finished one way or the other.

  ## The note under each row is where the honesty goes

  A network's row carries its signal, what security it advertises, and
  whether this device already knows it. Two of the five kinds of security
  cannot be joined from this screen at all -- enterprise and WEP, see
  `MayonnaiOS.WiFi` -- and those rows say what they would need where the
  others say how to join. The same rule as `MayonnaiOS.Scene.Pairing`'s
  headphone notice: a row that takes a passphrase and then fails is worse
  than a row that says it cannot take one.

  ## The passphrase is monospaced, and that is load-bearing

  The caret is a rectangle drawn under one character. In a proportional font
  its position is the measured width of every character before it, which
  drifts against the glyph it is meant to sit under as the string grows. In a
  monospaced one it is a multiplication. So the wheel's string is set in
  `:roboto_mono` at a size and column count that put sixty-three characters
  -- WPA's maximum -- on two lines that fit the panel.

  ## Building a page is a pure function

  `graph/1` takes the snapshot and needs no viewport, no driver and no
  framebuffer, which is what lets the host tests assert on an empty list, a
  row armed for forgetting, a refused passphrase and a machine with no radio
  at all -- states that would otherwise only be reachable by holding the
  device in the right room.
  """

  use Scenic.Scene

  alias MayonnaiOS.Scene.StatusBar
  alias MayonnaiOS.Theme
  alias MayonnaiOS.WiFi.App
  alias MayonnaiOS.WiFi.Editor
  alias Scenic.Graph

  import Scenic.Primitives

  @width 640
  @height 480

  # The shared top bar owns the top of the panel on every screen, so
  # everything here starts below it and the height comes from the bar rather
  # than being copied.
  @status_bar StatusBar.height()
  @title_y @status_bar + 20
  @rule_y @status_bar + 30

  @connection_y @rule_y + 26
  @heading_y @connection_y + 30

  @top @heading_y + 22
  @pitch 34
  @visible 8

  @left 20
  @row_width @width - 40

  @footer_rule @height - 44
  @footer_y @height - 24

  # The passphrase wheel. Forty columns of mono at 20 px fits the panel with
  # a margin, and two lines of forty covers the sixty-three characters WPA
  # allows.
  @mono :roboto_mono
  @psk_size 20
  @psk_columns 40
  @psk_pitch 30
  @psk_y @rule_y + 92

  # Read at the moment of drawing rather than captured in a module attribute,
  # so the System menu's Theme row changes this screen too without a
  # recompile. See `MayonnaiOS.Theme`.
  defp font, do: Theme.current().font
  defp bg, do: Theme.current().bg
  defp title, do: Theme.current().title
  defp head, do: Theme.current().head
  defp label, do: Theme.current().label
  defp pass, do: Theme.current().pass
  defp fail, do: Theme.current().fail
  defp wait, do: Theme.current().wait
  defp dim, do: Theme.current().dim
  defp row_bg, do: Theme.current().row_bg

  @impl Scenic.Scene
  def init(scene, _param, _opts) do
    {:ok, show(scene, watch())}
  end

  @impl GenServer
  def handle_info({:wifi_app, snapshot}, scene), do: {:noreply, show(scene, snapshot)}
  def handle_info(_message, scene), do: {:noreply, scene}

  # The app not running is a state to render rather than crash on: it is what
  # the launcher shows if starting failed, and the panel is the only place
  # that is visible.
  defp watch do
    App.watch(self())
  rescue
    _error -> :stopped
  catch
    :exit, _reason -> :stopped
  end

  defp show(scene, snapshot), do: push_graph(scene, graph(snapshot))

  @doc """
  The height of the strip this scene leaves for the shared top bar, public so
  a test can assert that nothing is drawn above it.
  """
  @spec status_bar() :: pos_integer()
  def status_bar, do: @status_bar

  @doc """
  How many rows of the list are on screen at once, public for the same reason
  the windowing is tested at all: a cursor past the last visible row has to
  bring the window with it.
  """
  @spec visible() :: pos_integer()
  def visible, do: @visible

  @doc """
  Build the page for one snapshot.

  Public because it is the tested surface: `:stopped` is a valid argument and
  renders the "not running" page.
  """
  @spec graph(map() | :stopped) :: Scenic.Graph.t()
  def graph(snapshot)

  def graph(:stopped) do
    base()
    |> text("Not running", font_size: 26, fill: {:color, fail()}, translate: {@left, 120})
    |> footer("B or Menu goes back.")
  end

  def graph(%{status: :editing} = snapshot) do
    base()
    |> connection_line(snapshot)
    |> text("Passphrase for #{quoted(snapshot.editor.ssid)}",
      font_size: 18,
      fill: {:color, title()},
      translate: {@left, @heading_y}
    )
    |> passphrase(snapshot)
    |> footer("D-pad picks characters, L1/R1 jump blocks, Y removes, A joins, B cancels.")
  end

  def graph(%{status: :joining} = snapshot) do
    base()
    |> connection_line(snapshot)
    |> text("Joining #{quoted(ssid_of(snapshot))}...",
      font_size: 24,
      fill: {:color, wait()},
      translate: {@left, @heading_y + 20}
    )
    |> text("Waiting for the access point, and then for an address.",
      font_size: 15,
      fill: {:color, label()},
      translate: {@left, @heading_y + 48}
    )
    |> lines(@heading_y + 76, [
      {"The network this device was already on is untouched.", dim()}
    ])
    |> footer("B or Menu leaves. The radio carries on joining without this screen.")
  end

  def graph(%{status: :joined} = snapshot) do
    base()
    |> connection_line(snapshot)
    |> text("Joined #{quoted(ssid_of(snapshot))}",
      font_size: 26,
      fill: {:color, pass()},
      translate: {@left, @heading_y + 20}
    )
    |> lines(@heading_y + 52, joined_lines(snapshot))
    |> footer("A goes back to the list. B or Menu leaves.")
  end

  def graph(%{status: :failed} = snapshot) do
    base()
    |> connection_line(snapshot)
    |> text(headline(snapshot.error),
      font_size: 24,
      fill: {:color, fail()},
      translate: {@left, @heading_y + 20}
    )
    |> lines(@heading_y + 52, explain(snapshot.error, snapshot))
    |> footer("A goes back to the list. B or Menu leaves.")
  end

  # :listing, and anything else the app has not got a page of its own for.
  def graph(snapshot) do
    base()
    |> connection_line(snapshot)
    |> heading(snapshot)
    |> rows(snapshot)
    |> footer(bindings(snapshot))
  end

  # -- the furniture every page shares ----------------------------------------

  defp base do
    Graph.build(font: font(), font_size: 14)
    |> rect({@width, @height}, fill: {:color, bg()})
    |> StatusBar.mount()
    |> text("WiFi", font_size: 20, fill: {:color, title()}, translate: {@left, @title_y})
    |> rect({@row_width, 2}, fill: {:color, head()}, translate: {@left, @rule_y})
  end

  # One line saying where the radio is now, on every page. It is the thing
  # somebody opening this screen is checking, and it is also the answer to
  # "did that work" on the pages that follow a join.
  defp connection_line(graph, %{available?: false}) do
    text(graph, "No WiFi radio on this machine.",
      font_size: 15,
      fill: {:color, dim()},
      translate: {@left, @connection_y}
    )
  end

  defp connection_line(graph, %{connection: connection}) do
    {words, colour} = connection_words(connection)

    text(graph, words, font_size: 15, fill: {:color, colour}, translate: {@left, @connection_y})
  end

  defp connection_line(graph, _snapshot), do: graph

  defp connection_words(%{state: state, ssid: ssid, address: address}) do
    case state do
      :internet -> {"On #{name(ssid)}#{at(address)}", pass()}
      # Associated and addressed, with nothing beyond the router answering.
      # A working join and a separate problem, so it is not drawn as a
      # failure.
      :lan -> {"On #{name(ssid)}#{at(address)} -- no route to the internet", wait()}
      :disconnected -> {"Not connected", fail()}
      nil -> {"No reading from the radio", dim()}
      other -> {"Radio says #{inspect(other)}", dim()}
    end
  end

  defp name(nil), do: "an unnamed network"
  defp name(ssid), do: quoted(ssid)

  defp at(nil), do: ""
  defp at(address), do: ", #{address}"

  defp heading(graph, snapshot) do
    count = length(snapshot.networks)

    graph
    |> text("Networks (#{count})",
      font_size: 15,
      fill: {:color, head()},
      translate: {@left, @heading_y}
    )
    |> rect({@row_width, 1}, fill: {:color, dim()}, translate: {@left, @heading_y + 6})
  end

  # -- the list ---------------------------------------------------------------

  defp rows(graph, %{networks: []} = snapshot) do
    lines(graph, @top, empty_lines(snapshot))
  end

  defp rows(graph, snapshot) do
    {start, window} = window(snapshot.networks, snapshot.cursor)

    window
    |> Enum.with_index(start)
    |> Enum.reduce(graph, fn {network, index}, acc ->
      selected? = index == snapshot.cursor
      y = @top + (index - start) * @pitch

      acc
      |> highlight(y, selected?)
      |> text(clip(network.ssid),
        font_size: 17,
        fill: {:color, ssid_colour(network, selected?)},
        translate: {@left + 16, y + 4}
      )
      |> text(note(network, selected? and snapshot.armed?),
        font_size: 12,
        fill: {:color, note_colour(network, selected? and snapshot.armed?)},
        translate: {@left + 16, y + 19}
      )
    end)
    |> more(start, length(snapshot.networks))
  end

  defp empty_lines(%{available?: false}) do
    [
      {"There is no radio here to scan with.", label()},
      {"vintage_net is a target-only dependency, so a host build has none.", dim()},
      {"The rest of this screen is drawn from whatever the machine can answer.", dim()}
    ]
  end

  defp empty_lines(%{scan_error: reason}) when not is_nil(reason) do
    [
      {"The scan did not start.", fail()},
      {inspect(reason), label()}
    ]
  end

  defp empty_lines(_snapshot) do
    [
      {"Scanning...", wait()},
      {"Nothing has answered yet. This rescans every few seconds.", dim()}
    ]
  end

  # Armed is the loudest thing on the row, because the next Y is the one that
  # does it and the row is otherwise indistinguishable from a selected one.
  defp note(_network, true), do: "press Y again to forget this network"

  defp note(network, _armed) do
    [signal(network.signal), security(network.security), tag(network)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("  ")
  end

  defp signal(nil), do: nil
  defp signal(percent), do: "#{percent}%"

  defp security(:open), do: "open"
  defp security(:wpa_psk), do: "WPA2"
  defp security(:sae), do: "WPA3"
  defp security(:wep), do: "WEP -- needs a key this screen cannot enter"
  defp security(:eap), do: "enterprise -- needs an identity and a certificate"
  defp security(:unknown), do: nil
  defp security(other), do: to_string(other)

  defp tag(%{connected?: true}), do: "connected"
  defp tag(%{saved?: true, in_range?: false}), do: "saved, not in range"
  defp tag(%{saved?: true}), do: "saved"
  defp tag(_network), do: nil

  defp ssid_colour(_network, true), do: title()
  defp ssid_colour(%{connected?: true}, _selected), do: pass()
  defp ssid_colour(_network, _selected), do: label()

  defp note_colour(_network, true), do: fail()
  defp note_colour(%{security: security}, _armed) when security in [:eap, :wep], do: wait()
  defp note_colour(_network, _armed), do: dim()

  defp highlight(graph, _y, false), do: graph

  defp highlight(graph, y, true) do
    graph
    |> rect({@row_width, @pitch - 4}, fill: {:color, row_bg()}, translate: {@left, y - 12})
    |> rect({4, @pitch - 4}, fill: {:color, head()}, translate: {@left, y - 12})
  end

  # Window the rows so a cursor past the last visible one is still on screen.
  defp window(rows, cursor) do
    count = length(rows)
    start = min(max(0, cursor - @visible + 1), max(0, count - @visible))
    {start, Enum.slice(rows, start, @visible)}
  end

  defp more(graph, _start, count) when count <= @visible, do: graph

  defp more(graph, start, count) do
    text(graph, "#{start + 1}-#{min(start + @visible, count)} of #{count}",
      font_size: 12,
      fill: {:color, dim()},
      translate: {@left, @top + @visible * @pitch}
    )
  end

  # -- the passphrase wheel ---------------------------------------------------

  defp passphrase(graph, %{editor: editor} = snapshot) do
    chars = editor.chars
    caret = min(editor.caret, length(chars))
    char_width = Theme.width("0", @psk_size, @mono)

    graph
    |> psk_lines(chars, char_width)
    |> psk_caret(caret, char_width, length(chars))
    |> lines(@psk_y + 2 * @psk_pitch + 24, psk_notes(editor, snapshot))
  end

  # The string, wrapped at the column count the panel fits. Empty draws a
  # prompt rather than nothing, because a screen with a caret on an empty line
  # and no words is a screen that looks broken.
  defp psk_lines(graph, [], _char_width) do
    text(graph, "press up or down to start",
      font_size: 15,
      fill: {:color, dim()},
      translate: {@left, @psk_y}
    )
  end

  defp psk_lines(graph, chars, _char_width) do
    chars
    |> Enum.chunk_every(@psk_columns)
    |> Enum.with_index()
    |> Enum.reduce(graph, fn {chunk, row}, acc ->
      text(acc, Enum.join(chunk),
        font: @mono,
        font_size: @psk_size,
        fill: {:color, title()},
        translate: {@left, @psk_y + row * @psk_pitch}
      )
    end)
  end

  # A rectangle under the character the wheel is on. Monospace is what makes
  # its position a multiplication rather than a measurement; see the
  # moduledoc.
  defp psk_caret(graph, caret, char_width, count) do
    row = div(caret, @psk_columns)
    column = rem(caret, @psk_columns)
    x = @left + column * char_width
    y = @psk_y + row * @psk_pitch + 6

    # Past the end of the string the caret is where the next character goes,
    # so it is drawn hollow -- a thinner mark than the one sitting under a
    # character somebody is cycling.
    thickness = if caret >= count, do: 2, else: 3

    rect(graph, {max(char_width, 1), thickness}, fill: {:color, head()}, translate: {x, y})
  end

  defp psk_notes(editor, snapshot) do
    {min, max} = Map.get(snapshot, :passphrase_bounds, {8, 63})
    length = Editor.length(editor)

    [
      {"#{length} characters. WPA accepts #{min} to #{max}.", length_colour(length, min, max)},
      {wheel_line(editor), dim()}
    ]
  end

  defp length_colour(length, min, max) when length >= min and length <= max, do: pass()
  defp length_colour(0, _min, _max), do: dim()
  defp length_colour(_length, _min, _max), do: wait()

  defp wheel_line(editor) do
    case Editor.current(editor) do
      nil -> "The caret is past the end: a direction adds a character there."
      char -> "Under the caret: #{quoted(char)}"
    end
  end

  # -- the pages after a join -------------------------------------------------

  defp joined_lines(%{connection: %{address: address}}) when is_binary(address) do
    [
      {"Address #{address}.", label()},
      {"Saved, so this network is rejoined after a power cut.", dim()}
    ]
  end

  defp joined_lines(_snapshot) do
    [
      {"Saved, so this network is rejoined after a power cut.", dim()}
    ]
  end

  defp headline(:wrong_key), do: "That passphrase was refused"
  defp headline(:timed_out), do: "No answer"
  defp headline(:passphrase_too_short), do: "Too short"
  defp headline(:passphrase_too_long), do: "Too long"
  defp headline(:eap_unsupported), do: "Enterprise networks cannot be joined here"
  defp headline(:wep_unsupported), do: "WEP networks cannot be joined here"
  defp headline(:unavailable), do: "No radio"
  defp headline(:not_saved), do: "Not saved"
  defp headline({:forget_failed, _reason}), do: "Could not forget it"
  defp headline(_other), do: "That did not work"

  defp explain(:wrong_key, snapshot) do
    [
      {"#{name(ssid_of(snapshot))} rejected it, and it has been removed again.", label()},
      {"Nothing else changed: the network this device was already on is", dim()},
      {"still configured. A goes back to the list; X retries the passphrase.", dim()}
    ]
  end

  defp explain(:timed_out, snapshot) do
    [
      {"#{name(ssid_of(snapshot))} did not finish connecting in time.", label()},
      {"It is still configured, so it may yet connect -- the bar at the top", dim()},
      {"says so if it does. A slow router is the usual reason.", dim()}
    ]
  end

  defp explain(:passphrase_too_short, _snapshot) do
    [{"A WPA passphrase is at least 8 characters. Nothing was changed.", label()}]
  end

  defp explain(:passphrase_too_long, _snapshot) do
    [{"A WPA passphrase is at most 63 characters. Nothing was changed.", label()}]
  end

  defp explain(:eap_unsupported, _snapshot) do
    [
      {"802.1X wants an identity, a CA certificate and an inner method.", label()},
      {"None of that is a passphrase, and none of it can be picked from", dim()},
      {"a character wheel. Configure it over SSH with VintageNet.", dim()}
    ]
  end

  defp explain(:wep_unsupported, _snapshot) do
    [
      {"WEP wants a hex or ASCII key in one of four slots, and nothing", label()},
      {"on this device has associated with a WEP access point to say the", dim()},
      {"plumbing works. Configure it over SSH if you really have one.", dim()}
    ]
  end

  defp explain(:unavailable, _snapshot) do
    [
      {"vintage_net is not loaded, so there is nothing to configure.", label()},
      {"That is the normal state of a host build.", dim()}
    ]
  end

  defp explain(:not_saved, _snapshot) do
    [{"The network is not in the configuration any more. Nothing changed.", label()}]
  end

  defp explain({:forget_failed, reason}, _snapshot) do
    [
      {"The configuration was refused: #{inspect(reason)}.", label()},
      {"See the log: RingLogger.next", dim()}
    ]
  end

  defp explain(other, _snapshot) do
    [
      {inspect(other), label()},
      {"See the log: RingLogger.next", dim()}
    ]
  end

  # -- footers ----------------------------------------------------------------

  defp bindings(%{networks: []}), do: "B or Menu goes back."

  defp bindings(%{armed?: true}) do
    "Y forgets this network. Any direction or B cancels. Menu leaves."
  end

  defp bindings(snapshot) do
    case snapshot.selected do
      nil -> "B or Menu goes back."
      network -> row_bindings(network)
    end
  end

  defp row_bindings(%{security: security}) when security in [:eap, :wep] do
    "This one cannot be joined from here. B or Menu goes back."
  end

  defp row_bindings(%{connected?: true}), do: "X retypes the passphrase, Y forgets. B goes back."

  defp row_bindings(%{saved?: true}), do: "A joins, X retypes the passphrase, Y forgets."

  defp row_bindings(%{security: :open}), do: "A joins this open network. B or Menu goes back."

  defp row_bindings(_network), do: "A picks a passphrase and joins. B or Menu goes back."

  defp footer(graph, words) do
    graph
    |> rect({@row_width, 1}, fill: {:color, dim()}, translate: {@left, @footer_rule})
    |> text(words, font_size: 14, fill: {:color, dim()}, translate: {@left, @footer_y})
  end

  # -- shared bits ------------------------------------------------------------

  # The value/label column the other screens on this device use, so the set
  # reads as one machine.
  defp lines(graph, y, rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce(graph, fn {{words, colour}, index}, acc ->
      text(acc, words,
        font_size: 15,
        fill: {:color, colour},
        translate: {@left, y + index * 22}
      )
    end)
  end

  defp ssid_of(%{target: %{ssid: ssid}}), do: ssid
  defp ssid_of(%{connection: %{ssid: ssid}}), do: ssid
  defp ssid_of(_snapshot), do: nil

  defp quoted(nil), do: "(unnamed)"
  defp quoted(text), do: "\"#{text}\""

  # A 32-byte SSID -- the maximum -- at font size 17 runs off the panel, and
  # Scenic will happily draw it over the footer.
  defp clip(text) when byte_size(text) <= 46, do: text
  defp clip(text), do: binary_part(text, 0, 45) <> "…"
end
