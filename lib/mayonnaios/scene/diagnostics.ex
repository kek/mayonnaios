defmodule MayonnaiOS.Scene.Diagnostics do
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

  ## Once a second, unless a program owns the panel

  This is the only screen in this firmware that redraws itself on a clock
  while the launcher may have handed the display to somebody else. Press X
  during a game, or start a game from this screen, and the scene stays alive
  with its one-second refresh running: every refresh is a changed graph, and
  Scenic writing `/dev/fb0` under a program that holds DRM hangs this board.

  So the refresh goes through `MayonnaiOS.Panel.draw/2` rather than
  `push_graph/2`. The timer keeps running and the snapshot keeps being taken;
  only the write waits. The launcher repaints on the way back, so the screen
  is current again a frame after the program exits.
  """

  use Scenic.Scene

  alias Scenic.Graph
  alias MayonnaiOS.{Audio, Diagnostics, Panel}
  alias MayonnaiOS.Scene.StatusBar
  import Scenic.Primitives

  @width 640
  @height 480

  # The shared top bar owns the top of the panel on every screen, so the title
  # starts below it. The height comes from the bar rather than being copied.
  @status_bar StatusBar.height()
  @title_y @status_bar + 20
  @rule_y @status_bar + 30

  # Where the two columns start. The 22 px the bar took came off the top of
  # both, and the right-hand column is the tight one: its four sections come
  # to 374 px, which from here ends at 458 on a 480 px panel.
  @column_y @rule_y + 24

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
    {:ok, Panel.draw(scene, graph(snapshot()))}
  end

  @impl GenServer
  def handle_info(:refresh, scene), do: {:noreply, Panel.draw(scene, graph(snapshot()))}
  def handle_info(_msg, scene), do: {:noreply, scene}

  # The scene must survive the collector not running -- on the host it never
  # does, and a diagnostics screen that crashes is worse than no diagnostics.
  #
  # The exit clause is not decoration. Diagnostics.snapshot/0 is a call, and
  # the collector now has one handler that can block it for seconds: the
  # Bluetooth probe waits on HCI commands. A call that times out exits, and
  # exits are not rescued -- without this the panel would die exactly when
  # somebody was using it to watch a probe.
  defp snapshot do
    if Process.whereis(Diagnostics), do: Diagnostics.snapshot(), else: nil
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # -- rendering -------------------------------------------------------------

  @doc """
  Build the graph for one `MayonnaiOS.Diagnostics.snapshot/0`, or for `nil`.

  Public for the same reason the other screens' builders are: it needs no
  viewport, no driver and no framebuffer, so a host test can assert what the
  panel says -- including that nothing is drawn in the strip the shared top
  bar owns.
  """
  @spec graph(Diagnostics.t() | nil) :: Scenic.Graph.t()
  def graph(snapshot)

  def graph(nil) do
    base()
    |> text("Diagnostics collector is not running.",
      font_size: 18,
      fill: {:color, @fail},
      translate: {20, @column_y + 18}
    )
  end

  def graph(s) do
    base()
    |> column(20, left_rows(s))
    |> column(330, right_rows(s))
  end

  defp base do
    Graph.build(font: :roboto, font_size: 14)
    |> rect({@width, @height}, fill: {:color, @bg})
    |> StatusBar.mount()
    |> text("RG40XXV diagnostics",
      font_size: 20,
      fill: {:color, @title},
      translate: {20, @title_y}
    )
    |> rect({@width - 40, 2}, fill: {:color, @head}, translate: {20, @rule_y})
  end

  # Walk a column of entries, advancing a y cursor. Headings get extra space
  # above them, so sections read as sections.
  defp column(graph, x, entries) do
    {graph, _y} =
      Enum.reduce(entries, {graph, @column_y}, fn
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
    [{:row, "client", "none", @dim}, {:row, "• press A", "launch a program", @wait}]
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
    # hci0 exists whether or not setup succeeded, so it is shown but never
    # coloured green on its own. The row that decides is "firmware", which
    # reports what btrtl said while setting the controller up.
    #
    # There used to be an "address" row here, reading
    # /sys/class/bluetooth/hci0/address. This kernel does not expose that
    # attribute, so it read "none" on a working controller and sent someone
    # looking for a fault that had already been fixed.
    {firmware, colour} =
      case bt[:rtl] do
        {:ok, version} -> {"ok #{version}", @pass}
        {:error, reason} -> {reason, @fail}
        _ -> {"unknown", @wait}
      end

    [
      {:row, "hci0", yn(bt[:hci0]), if(bt[:hci0], do: @dim, else: @fail)},
      {:row, "config blob", yn(bt[:config_firmware]),
       if(bt[:config_firmware], do: @pass, else: @fail)},
      {:row, "firmware", firmware, colour}
    ] ++ probe_rows(bt[:probe])
  end

  # The only row here that reflects the controller answering rather than the
  # kernel log remembering. Amber until somebody runs it: not run is not the
  # same as not working, and this panel's whole point is keeping those apart.
  #
  # One row, not two. There is no button bound to the probe -- it is
  # `Diagnostics.probe_bluetooth()` over SSH, because it takes hci0 away from
  # the kernel while it runs -- and a second row explaining that pushes the
  # headphone-jack rows into the hint line at the bottom of a 480px panel.
  defp probe_rows(probe) do
    {value, colour} =
      case probe do
        {:ok, v} -> {"#{v.manufacturer_name} #{v.core_spec}", @pass}
        {:error, :not_run} -> {"not run", @wait}
        {:error, reason} -> {inspect(reason), @fail}
        _ -> {"unknown", @wait}
      end

    [{:row, "probe", value, colour}]
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

  # Muted controls are amber, not red: silent at 0% is the state this device
  # is *set* to at boot, not a fault. The tone is no longer on a button, so
  # this row says whether calling it would do anything rather than what to
  # press.
  defp audio_state do
    if Audio.enabled?(), do: "armed — Audio.run/0", else: "off (silent)"
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
