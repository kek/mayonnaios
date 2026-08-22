defmodule MayonnaiOS.Scene.Pairing do
  @moduledoc """
  What the panel shows while the Bluetooth devices app has the buttons.

  Two lists side by side, and a line at the top saying what the screen cannot
  do. The two lists are deliberately not the same kind of thing:

      Paired hosts   the LE bonds. Selectable; A forgets one.
      Nearby         what is advertising. Informational, no cursor.

  ## The notice is at the top, not in a footnote

  Someone opening this screen is looking for their headphones. They are not
  going to be found, because Bluetooth audio is A2DP over BR/EDR and this
  firmware has no BR/EDR host at all -- see `MayonnaiOS.Pairing` for the full
  list of what is missing and why it starts with a Buildroot rebuild. A screen
  that puts that at the bottom, in grey, is a screen that has technically said
  it.

  So it is the first thing under the rule, in amber, and every nearby row that
  advertises BR/EDR support carries `needs BR/EDR` where a Connect button
  would otherwise be. That tag is read out of the advertisement's own Flags
  byte rather than guessed from the name.

  ## A device with no name is a row with an address on it

  Not "(unknown)". Two nameless devices are then two distinguishable rows, and
  a scan that produces nothing but addresses is a scan running passively or a
  room full of beacons -- both of which are visible from the rows themselves
  rather than needing a log.

  ## Building the graph is a pure function

  `graph/1` takes the map `MayonnaiOS.Pairing.status/0` returns and needs no
  viewport, no driver and no framebuffer, which is what lets the host tests
  assert on the empty list, a bond armed for deletion, and a scan that failed
  to start -- three states that would otherwise only be findable by holding
  the device.
  """

  use Scenic.Scene

  alias MayonnaiOS.Pairing
  alias Scenic.Graph

  import Scenic.Primitives

  @width 640
  @height 480

  # The palette every other screen on this device uses.
  @bg {12, 14, 22}
  @title {235, 238, 245}
  @head {90, 170, 255}
  @label {150, 165, 195}
  @pass {120, 220, 150}
  @fail {245, 110, 120}
  @wait {235, 190, 90}
  @dim {110, 125, 155}
  @row_bg {26, 34, 52}

  @top 148
  @pitch 34
  @visible 8

  @left 20
  @right 330
  @column_width 290

  @refresh_ms 500

  @impl Scenic.Scene
  def init(scene, param, _opts) do
    :timer.send_interval(@refresh_ms, :refresh)
    error = if is_map(param), do: Map.get(param, :error), else: nil

    {:ok, scene |> assign(error: error) |> refresh()}
  end

  @impl GenServer
  def handle_info(:refresh, scene), do: {:noreply, refresh(scene)}
  def handle_info(_message, scene), do: {:noreply, scene}

  defp refresh(scene), do: push_graph(scene, graph(status(), scene.assigns[:error]))

  # The app not running has to render rather than crash: it is what the
  # launcher shows when starting failed, and the reason is the only useful
  # thing on the panel at that moment.
  defp status do
    Pairing.status()
  rescue
    _ -> :stopped
  catch
    :exit, _ -> :stopped
  end

  @doc """
  Build the graph for one `MayonnaiOS.Pairing.status/0` reading.

  Public because it is the tested surface. `:stopped` and an error reason are
  a valid pair of arguments and render the "not running" page.
  """
  @spec graph(map() | :stopped, term()) :: Scenic.Graph.t()
  def graph(status, error \\ nil)

  def graph(:stopped, error) do
    base()
    |> text("Not running", font_size: 26, fill: {:color, @fail}, translate: {20, 90})
    |> text(reason(error), font_size: 16, fill: {:color, @label}, translate: {20, 120})
    |> column(20, 160, explain(error))
    |> footer("Menu goes back.")
  end

  def graph(status, _error) do
    base()
    |> notice()
    |> heading(@left, "Paired hosts", count(status.bonds))
    |> heading(@right, "Nearby", nearby_count(status))
    |> bonds(status)
    |> nearby(status)
    |> footer(bindings(status))
  end

  defp base do
    Graph.build(font: :roboto, font_size: 14)
    |> rect({@width, @height}, fill: {:color, @bg})
    |> text("Bluetooth devices", font_size: 20, fill: {:color, @title}, translate: {20, 28})
    |> rect({@width - 40, 2}, fill: {:color, @head}, translate: {20, 38})
  end

  # The one thing this screen exists to be honest about.
  defp notice(graph) do
    graph
    |> text("Headphones cannot be connected from here.",
      font_size: 18,
      fill: {:color, @wait},
      translate: {20, 66}
    )
    |> text("Audio is A2DP over BR/EDR, and this firmware has no BR/EDR host at all.",
      font_size: 13,
      fill: {:color, @label},
      translate: {20, 88}
    )
    |> text("What works: seeing what is nearby, and managing pairings made as a gamepad.",
      font_size: 13,
      fill: {:color, @dim},
      translate: {20, 106}
    )
  end

  defp heading(graph, x, title, count) do
    graph
    |> text("#{title} (#{count})", font_size: 15, fill: {:color, @head}, translate: {x, 132})
    |> rect({@column_width, 1}, fill: {:color, @dim}, translate: {x, 138})
  end

  # -- the bonds, which are the only selectable thing here --------------------

  defp bonds(graph, %{bonds: []}) do
    text(graph, "Nothing paired.", font_size: 15, fill: {:color, @dim}, translate: {@left, @top})
  end

  defp bonds(graph, status) do
    {start, rows} = window(status.bonds, status.selected)

    rows
    |> Enum.with_index(start)
    |> Enum.reduce(graph, fn {bond, index}, acc ->
      selected? = index == status.selected
      y = @top + (index - start) * @pitch

      acc
      |> highlight(y, selected?)
      |> text(bond.address,
        font_size: 17,
        fill: {:color, if(selected?, do: @title, else: @label)},
        translate: {@left + 16, y + 4}
      )
      |> text(bond_note(bond, selected? and status.armed),
        font_size: 12,
        fill: {:color, bond_note_colour(selected? and status.armed)},
        translate: {@left + 16, y + 19}
      )
    end)
    |> more(@left, start, length(status.bonds))
  end

  # Armed is the loudest thing on the row, because the next A is the one that
  # does it and the row is otherwise indistinguishable from a selected one.
  defp bond_note(_bond, true), do: "press A again to forget"
  defp bond_note(bond, _armed), do: "#{address_kind(bond)}, #{key_size(bond.key_size)}"

  # A resolvable private address changes every fifteen minutes on the host
  # that generated it, so it is not something to match against a machine in
  # front of you -- worth saying on the row rather than letting someone try.
  defp address_kind(%{random?: true}), do: "random address"
  defp address_kind(_bond), do: "public address"

  # The negotiated key size, in bits. Shown because a short one is the visible
  # end of a pairing that was downgraded, and 16 bytes is what this stack asks
  # for every time.
  defp key_size(size) when is_integer(size), do: "#{size * 8}-bit key"
  defp key_size(_size), do: "key size unknown"

  defp bond_note_colour(true), do: @fail
  defp bond_note_colour(_), do: @dim

  # -- what is on the air -----------------------------------------------------

  defp nearby(graph, %{scan: %{scanning: false} = scan}) do
    graph
    |> text("Scan did not start.",
      font_size: 15,
      fill: {:color, @fail},
      translate: {@right, @top}
    )
    |> text(reason(scan.error),
      font_size: 12,
      fill: {:color, @label},
      translate: {@right, @top + 18}
    )
  end

  defp nearby(graph, %{devices: []}) do
    graph
    |> text("Scanning...", font_size: 15, fill: {:color, @wait}, translate: {@right, @top})
    |> text("Nothing has advertised yet.",
      font_size: 12,
      fill: {:color, @dim},
      translate: {@right, @top + 18}
    )
  end

  defp nearby(graph, %{devices: devices}) do
    shown = Enum.take(devices, @visible)

    shown
    |> Enum.with_index()
    |> Enum.reduce(graph, fn {device, index}, acc ->
      y = @top + index * @pitch

      acc
      |> text(clip(device.label),
        font_size: 17,
        fill: {:color, name_colour(device)},
        translate: {@right, y + 4}
      )
      |> text(device_note(device),
        font_size: 12,
        fill: {:color, note_colour(device)},
        translate: {@right, y + 19}
      )
    end)
    |> more(@right, 0, length(devices))
  end

  # Signal, age, and the transport. The transport is the part that matters:
  # "needs BR/EDR" is where a Connect button would be on a screen that could
  # honestly offer one.
  defp device_note(device) do
    [signal(device.rssi), transport(device.dual_mode?), age(device.age_ms)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("  ")
  end

  defp signal(nil), do: nil
  defp signal(rssi), do: "#{rssi} dBm"

  defp transport(true), do: "needs BR/EDR"
  defp transport(false), do: "LE only"
  # No Flags structure has arrived yet, which is not the same as LE-only and
  # is not worth guessing about on a row that refreshes twice a second.
  defp transport(nil), do: nil

  # Only once it is worth saying. Everything in a live scan is a second old.
  defp age(age_ms) when age_ms < 5_000, do: nil
  defp age(age_ms), do: "#{div(age_ms, 1000)}s ago"

  defp name_colour(%{name: nil}), do: @dim
  defp name_colour(_device), do: @label

  defp note_colour(%{dual_mode?: true}), do: @wait
  defp note_colour(%{dual_mode?: false}), do: @pass
  defp note_colour(_device), do: @dim

  # -- shared furniture -------------------------------------------------------

  defp highlight(graph, _y, false), do: graph

  defp highlight(graph, y, true) do
    graph
    |> rect({@column_width, @pitch - 4}, fill: {:color, @row_bg}, translate: {@left, y - 12})
    |> rect({4, @pitch - 4}, fill: {:color, @head}, translate: {@left, y - 12})
  end

  # Window the rows so a selection past the eighth entry is still on screen.
  defp window(rows, selected) do
    count = length(rows)
    start = min(max(0, selected - @visible + 1), max(0, count - @visible))
    {start, Enum.slice(rows, start, @visible)}
  end

  defp more(graph, _x, _start, count) when count <= @visible, do: graph

  defp more(graph, x, start, count) do
    text(graph, "#{start + 1}-#{min(start + @visible, count)} of #{count}",
      font_size: 12,
      fill: {:color, @dim},
      translate: {x, @top + @visible * @pitch}
    )
  end

  defp bindings(%{bonds: []}), do: "Menu goes back."
  defp bindings(%{armed: true}), do: "A forgets this pairing. Any direction cancels. Menu leaves."
  defp bindings(_status), do: "D-pad picks a pairing, A forgets it. Menu goes back."

  defp footer(graph, message) do
    graph
    |> rect({@width - 40, 1}, fill: {:color, @dim}, translate: {20, @height - 44})
    |> text(message, font_size: 14, fill: {:color, @dim}, translate: {20, @height - 24})
  end

  defp count(list), do: length(list)

  defp nearby_count(%{scan: %{devices: n}}), do: n

  # A 31-byte name at font size 17 runs off the panel and Scenic will happily
  # draw it over the footer.
  defp clip(text) when byte_size(text) <= 22, do: text
  defp clip(text), do: binary_part(text, 0, 21) <> "…"

  defp reason(nil), do: ""
  defp reason(reason), do: inspect(reason)

  defp explain(:eusers) do
    [
      {"", "Something else already has hci0.", @label},
      {"", "The controller app holds it while it", @dim},
      {"", "runs; stop it and try again.", @dim}
    ]
  end

  defp explain({:already_started, _pid}) do
    [
      {"", "The Bluetooth stack is already up.", @label},
      {"", "The controller app is running.", @dim}
    ]
  end

  defp explain(:enodev) do
    [
      {"", "There is no hci0 at all.", @label},
      {"", "The Realtek firmware did not load;", @dim},
      {"", "dmesg at boot says why.", @dim}
    ]
  end

  defp explain(:eafnosupport) do
    [{"", "This machine has no Bluetooth sockets.", @label}]
  end

  defp explain(nil), do: [{"", "The app is not running.", @label}]
  defp explain(_other), do: [{"", "See the log: RingLogger.next", @dim}]

  # The same value/label column the controller and diagnostics screens use, so
  # the three read as one device.
  defp column(graph, x, y, rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce(graph, fn {{value, label, colour}, index}, acc ->
      top = y + index * @pitch

      acc
      |> text(value, font_size: 18, fill: {:color, colour}, translate: {x, top})
      |> text(label, font_size: 12, fill: {:color, colour}, translate: {x, top + 15})
    end)
  end
end
