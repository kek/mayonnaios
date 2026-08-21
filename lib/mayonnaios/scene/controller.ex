defmodule MayonnaiOS.Scene.Controller do
  @moduledoc """
  What the panel shows while the handheld is being a gamepad.

  The buttons are going somewhere else, so this screen has exactly one job:
  say how far along the connection is, in a form that is readable from across
  a desk while looking mostly at the other machine's screen.

  ## The stages are the diagnosis

  Getting a BLE HID device onto a host has four steps and any of them can be
  where it stops:

      advertising    on the air, nobody has connected
      connected      a host is talking to us but the link is in the clear
      paired         encrypted, so the HID service is readable
      ready          the host has subscribed and is receiving reports

  Every one of those looks identical from the host's side -- a controller
  that does nothing -- and completely different from here. That is the whole
  reason this screen exists rather than a spinner: "connected but never
  paired" is a host that needs the pairing finished in its settings, and
  "paired but not subscribed" is a host that has not decided the device is a
  gamepad, and those have different fixes.

  ## The counters

  Reports sent, and reports dropped with the reason. A device that says
  `ready` and whose sent counter is not climbing while buttons are being
  pressed is a different fault again -- and one that would otherwise need SSH
  to see.
  """

  use Scenic.Scene

  alias MayonnaiOS.Controller
  alias Scenic.Graph

  import Scenic.Primitives

  @width 640
  @height 480

  @bg {12, 14, 22}
  @title {235, 238, 245}
  @head {90, 170, 255}
  @label {150, 165, 195}
  @pass {120, 220, 150}
  @fail {245, 110, 120}
  @wait {235, 190, 90}
  @dim {110, 125, 155}

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

  defp refresh(scene) do
    push_graph(scene, render(status(), scene.assigns[:error]))
  end

  # The app not running is a state this scene has to render rather than crash
  # on: it is what the launcher shows when starting failed, and the reason is
  # the only useful thing on the screen at that moment.
  defp status do
    Controller.status()
  rescue
    _ -> :stopped
  catch
    :exit, _ -> :stopped
  end

  # -- rendering --------------------------------------------------------------

  defp render(:stopped, error) do
    base()
    |> text("Not running", font_size: 26, fill: {:color, @fail}, translate: {20, 90})
    |> text(reason(error), font_size: 16, fill: {:color, @label}, translate: {20, 120})
    |> column(20, 160, explain(error))
    |> footer("Menu goes back.")
  end

  defp render(status, _error) do
    base()
    |> text(headline(status), font_size: 26, fill: {:color, colour(status)}, translate: {20, 90})
    |> text(subtitle(status), font_size: 16, fill: {:color, @label}, translate: {20, 118})
    |> column(20, 160, stages(status))
    |> column(330, 160, facts(status))
    |> footer("Menu leaves. Until then every button goes to the host.")
  end

  defp base do
    Graph.build(font: :roboto, font_size: 14)
    |> rect({@width, @height}, fill: {:color, @bg})
    |> text("Bluetooth controller", font_size: 20, fill: {:color, @title}, translate: {20, 28})
    |> rect({@width - 40, 2}, fill: {:color, @head}, translate: {20, 38})
  end

  defp footer(graph, message) do
    graph
    |> rect({@width - 40, 1}, fill: {:color, @dim}, translate: {20, @height - 44})
    |> text(message, font_size: 14, fill: {:color, @dim}, translate: {20, @height - 24})
  end

  defp headline(%{subscribed: true, encrypted: true}), do: "Ready"
  defp headline(%{encrypted: true}), do: "Paired"
  defp headline(%{connected: true}), do: "Connected"
  defp headline(%{advertising: true}), do: "Waiting to be paired"
  defp headline(_status), do: "Off the air"

  defp colour(%{subscribed: true, encrypted: true}), do: @pass
  defp colour(%{connected: true}), do: @wait
  defp colour(%{advertising: true}), do: @wait
  defp colour(_status), do: @fail

  defp subtitle(%{subscribed: true, encrypted: true}), do: "Buttons are going to the host."
  defp subtitle(%{encrypted: true}), do: "Waiting for the host to ask for reports."
  defp subtitle(%{connected: true}), do: "Finish pairing on the host."
  defp subtitle(%{advertising: true, name: name}), do: "Look for #{name}."
  defp subtitle(_status), do: "Advertising did not start; the log has the reason."

  # Each stage, with the one that has not happened yet as the live edge. Shown
  # as a list rather than a single line because the interesting information is
  # which step it stopped at, not which step it reached.
  defp stages(status) do
    [
      {"Advertising", status.advertising or status.connected},
      {"Host connected", status.connected},
      {"Paired and encrypted", status.encrypted},
      # A host reads the report map once per pairing and then caches it. So
      # this row is also how you tell that a firmware whose buttons moved is
      # actually being read as the new layout rather than the old one.
      {"Report map read", status.report_map_read},
      {"Reports subscribed", status.subscribed}
    ]
    |> Enum.map(fn {label, done} ->
      {if(done, do: "done", else: "waiting"), label, if(done, do: @pass, else: @dim)}
    end)
  end

  defp facts(status) do
    [
      {status.name, "name", @label},
      {status.address || "unknown", "address", @label},
      {"#{status.mtu}", "att mtu", @label},
      {interval(status), "interval", interval_colour(status)},
      {"#{status.bonds}", "paired hosts", @label},
      {"#{status.sent}", "reports sent", if(status.sent > 0, do: @pass, else: @dim)},
      {dropped(status.dropped), "dropped", dropped_colour(status.dropped)}
    ]
  end

  # The connection interval, which is the floor on how late a button press can
  # be. Amber past 20 ms because that is where a press starts being felt as
  # late rather than measured as late.
  defp interval(%{interval_ms: nil}), do: "-"
  defp interval(%{interval_ms: ms}), do: "#{round(ms)} ms"

  defp interval_colour(%{interval_ms: ms}) when is_number(ms) and ms > 20, do: @wait
  defp interval_colour(_status), do: @label

  defp dropped(counts) do
    total = counts |> Map.values() |> Enum.sum()

    if total == 0 do
      "none"
    else
      # Name the reason with the highest count. All the reasons are ordinary
      # -- a host that has not subscribed yet drops every report until it does
      # -- so the number alone would read as a fault when it is usually just
      # the first second of a connection.
      {reason, count} = Enum.max_by(counts, &elem(&1, 1))
      "#{total} (#{count} #{reason})"
    end
  end

  defp dropped_colour(counts) do
    if Map.get(counts, :no_credits, 0) > 0, do: @fail, else: @dim
  end

  defp explain(nil) do
    [{"", "The app is not running.", @label}]
  end

  defp explain({:hci_status, _code} = _reason) do
    [{"", "The controller refused a command.", @label}]
  end

  defp explain(:eusers) do
    [
      {"", "Something else already has hci0.", @label},
      {"", "Diagnostics' Bluetooth probe holds it", @dim},
      {"", "briefly; try again in a moment.", @dim}
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
    # Only reachable on a development machine: macOS has no AF_BLUETOOTH at
    # all. Named anyway, because this scene is one of the things being looked
    # at while the app is run on a laptop.
    [{"", "This machine has no Bluetooth sockets.", @label}]
  end

  defp explain(_other) do
    [{"", "See the log: RingLogger.next", @dim}]
  end

  defp reason(nil), do: ""
  defp reason(reason), do: inspect(reason)

  # A column of value/label pairs, the same shape the diagnostics screen uses
  # so that the two read as one device rather than two programs.
  defp column(graph, x, y, rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce(graph, fn {{value, label, colour}, index}, acc ->
      top = y + index * 34

      acc
      |> text(value, font_size: 18, fill: {:color, colour}, translate: {x, top})
      |> text(label, font_size: 12, fill: {:color, @dim}, translate: {x, top + 15})
    end)
  end
end
