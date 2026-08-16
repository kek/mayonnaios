defmodule ScenicRg40xxv.Scene.Diagnostics do
  @moduledoc """
  The verification plan, on the panel, updating once a second.

  Some hardware cannot be checked from a desk. Nobody can pull the charger
  over SSH, or press a volume button, or plug in headphones. Those checks were
  going to be a list of instructions and a second machine; this makes them a
  glance at the screen while holding the device.

  Rows are coloured by what they mean rather than by what they are: green for
  a reading that proves the thing works, red for one that proves it does not,
  grey for "nobody has done the physical half yet". Grey is the important one.
  It is the difference between *tested and fine* and *not yet tested*, and
  collapsing those two is how the panel variant stayed open for two attempts.

  Rows marked with a bullet are waiting on a person. Press the button, pull
  the cable, and watch the row turn.
  """

  use Scenic.Scene

  alias Scenic.Graph
  alias ScenicRg40xxv.{Audio, Diagnostics}
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

  @refresh_ms 1_000

  @impl Scenic.Scene
  def init(scene, _param, _opts) do
    :timer.send_interval(@refresh_ms, :refresh)
    {:ok, push_graph(scene, render(snapshot()))}
  end

  @impl GenServer
  def handle_info(:refresh, scene), do: {:noreply, push_graph(scene, render(snapshot()))}
  def handle_info(_msg, scene), do: {:noreply, scene}

  # The scene must survive the collector not running -- on the host it never
  # does, and a diagnostics screen that crashes is worse than no diagnostics.
  defp snapshot do
    if Process.whereis(Diagnostics), do: Diagnostics.snapshot(), else: nil
  rescue
    _ -> nil
  end

  # -- rendering -------------------------------------------------------------

  defp render(nil) do
    base()
    |> text("Diagnostics collector is not running.",
      font_size: 18,
      fill: {:color, @fail},
      translate: {20, 80}
    )
  end

  defp render(s) do
    base()
    |> column(20, left_rows(s))
    |> column(330, right_rows(s))
    |> text(hints(), font_size: 13, fill: {:color, @dim}, translate: {20, @height - 16})
  end

  defp base do
    Graph.build(font: :roboto, font_size: 14)
    |> rect({@width, @height}, fill: {:color, @bg})
    |> text("RG40XXV diagnostics", font_size: 20, fill: {:color, @title}, translate: {20, 28})
    |> rect({@width - 40, 2}, fill: {:color, @head}, translate: {20, 38})
  end

  # Walk a column of entries, advancing a y cursor. Headings get extra space
  # above them, so sections read as sections.
  defp column(graph, x, entries) do
    {graph, _y} =
      Enum.reduce(entries, {graph, 62}, fn
        {:head, label}, {g, y} ->
          {text(g, label, font_size: 14, fill: {:color, @head}, translate: {x, y + 8}), y + 26}

        {:row, label, value, colour}, {g, y} ->
          g =
            g
            |> text(label, fill: {:color, @label}, translate: {x, y})
            |> text(value, fill: {:color, colour}, translate: {x + 120, y})

          {g, y + 18}
      end)

    graph
  end

  # -- left column: what has already been proved over SSH --------------------

  defp left_rows(s) do
    [{:head, "BATTERY"}] ++
      battery_rows(s.battery) ++
      [{:head, "THERMAL"}] ++
      thermal_rows(s.thermal) ++
      [{:head, "GPU"}] ++
      gpu_rows(s.gpu) ++
      [{:head, "REAL-TIME CLOCK"}] ++ rtc_rows(s.rtc)
  end

  defp battery_rows(b) do
    # A capacity that never moves is the failure that passes inspection, so
    # the reading is shown next to the current that explains it.
    capacity = if b[:capacity], do: "#{b.capacity} %", else: "--"

    status_colour =
      case b[:status] do
        "Charging" -> @pass
        "Discharging" -> @pass
        "Full" -> @pass
        nil -> @fail
        _ -> @wait
      end

    [
      {:row, "capacity", capacity, if(b[:capacity], do: @pass, else: @fail)},
      {:row, "status", b[:status] || "--", status_colour},
      {:row, "voltage", volts(b[:voltage_uv]), @dim},
      {:row, "current", amps(b[:current_ua]), @dim},
      {:row, "• pull cable", "status must flip", @wait}
    ]
  end

  defp thermal_rows([]), do: [{:row, "zones", "none", @fail}]

  defp thermal_rows(zones) do
    # No "press A and watch this rise" row here any more. It was wrong:
    # kmscube runs the GPU at about 5% and moves this sensor by 0.65 °C,
    # which is noise. These sensors are known good from a CPU load test
    # (+9.8 °C on cpu-thermal), and GPU work is measured directly below.
    Enum.map(zones, fn {type, milli} ->
      {:row, String.replace_suffix(type, "-thermal", ""), degrees(milli), @pass}
    end)
  end

  # Busy percentages from panfrost fdinfo. This is the honest answer to "is
  # the GPU doing anything", and unlike temperature it responds instantly.
  defp gpu_rows(%{client: nil}) do
    [{:row, "client", "none", @dim}, {:row, "• press A", "run kmscube", @wait}]
  end

  defp gpu_rows(%{client: name, engines: engines}) do
    rows =
      engines
      |> Enum.sort()
      |> Enum.map(fn {engine, percent} ->
        {:row, engine, if(percent, do: "#{percent} %", else: "..."),
         if(percent && percent > 0.0, do: @pass, else: @dim)}
      end)

    [{:row, "client", name, @pass}] ++ rows
  end

  defp rtc_rows(r) do
    [
      {:row, "clock", "#{r[:date] || "--"} #{r[:time] || ""}",
       if(r[:date], do: @pass, else: @fail)},
      {:row, "set at boot", if(r[:hctosys], do: "yes", else: "no"),
       if(r[:hctosys], do: @pass, else: @fail)}
    ]
  end

  # -- right column: what still needs a person -------------------------------

  defp right_rows(s) do
    [{:head, "BLUETOOTH"}] ++
      bluetooth_rows(s.bluetooth) ++
      [{:head, "AUDIO"}] ++
      audio_rows(s.audio) ++
      [{:head, "VOLUME BUTTONS"}] ++
      volume_rows(s.volume) ++
      [{:head, "HEADPHONE JACK"}] ++ jack_rows(s.jack)
  end

  defp bluetooth_rows(bt) do
    # hci0 exists whether or not setup succeeded. The address is what tells
    # the two apart, so it is the row that is coloured.
    [
      {:row, "hci0", yn(bt[:hci0]), if(bt[:hci0], do: @pass, else: @fail)},
      {:row, "address", bt[:address] || "none", if(bt[:address], do: @pass, else: @fail)},
      {:row, "config blob", yn(bt[:config_firmware]),
       if(bt[:config_firmware], do: @pass, else: @fail)}
    ]
  end

  defp audio_rows(a) do
    card = a[:card]

    controls =
      (a[:controls] || [])
      |> Enum.filter(& &1.name)
      |> Enum.take(4)
      |> Enum.map(fn c ->
        value =
          [if(c.percent, do: "#{c.percent}%"), if(c.on == nil, do: nil, else: on_off(c.on))]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" ")

        {:row, c.name, value, if(c.on == false, do: @wait, else: @pass)}
      end)

    [{:row, "card 0", yn(card), if(card, do: @pass, else: @fail)}] ++
      controls ++
      [{:row, "test", audio_state(), if(Audio.enabled?(), do: @pass, else: @dim)}]
  end

  # Muted controls are amber, not red: it is the expected default, and the
  # thing to fix before drawing any conclusion about the device tree.
  defp audio_state do
    if Audio.enabled?(), do: "armed — Y plays", else: "off (silent)"
  end

  defp volume_rows(v) do
    pressed = v[:up] > 0 and v[:down] > 0

    [
      {:row, "up", "#{v[:up]}", if(v[:up] > 0, do: @pass, else: @wait)},
      {:row, "down", "#{v[:down]}", if(v[:down] > 0, do: @pass, else: @wait)},
      {:row, "• press both", if(pressed, do: "confirmed", else: "waiting"),
       if(pressed, do: @pass, else: @wait)}
    ]
  end

  defp jack_rows(j) do
    state =
      case j[:inserted] do
        true -> {"inserted", @pass}
        false -> {"empty", @dim}
        nil -> {"unknown", @fail}
      end

    {label, colour} = state

    [
      {:row, "state", label, colour},
      {:row, "• plug/unplug", "#{j[:changes]} changes",
       if(j[:changes] > 0, do: @pass, else: @wait)}
    ]
  end

  defp hints do
    # X and Y as printed on the shell -- the device tree labels them the
    # other way round, and the buttons settled it.
    "X diagnostics/home   A cube   Start stop   Select+Menu power off"
  end

  # -- formatting ------------------------------------------------------------

  defp yn(true), do: "yes"
  defp yn(_), do: "no"

  defp on_off(true), do: "on"
  defp on_off(false), do: "OFF"

  defp volts(nil), do: "--"
  defp volts(uv), do: "#{Float.round(uv / 1_000_000, 3)} V"

  defp amps(nil), do: "--"
  defp amps(ua), do: "#{Float.round(ua / 1_000_000, 3)} A"

  defp degrees(nil), do: "--"
  defp degrees(milli), do: "#{Float.round(milli / 1000, 1)} °C"
end
