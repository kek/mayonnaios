defmodule MayonnaiOS.SystemInfo do
  @moduledoc """
  The system panel: what the root column's left slot says about the device.

  At the root of the column browser there is no parent column, so the left
  slot carries the glanceable facts about the machine itself instead: what
  firmware is running, how long it has been up, what address the network
  gave it, and how much room the writable partitions have left. The shape it
  returns is the same `%{kind: :info, title: ..., lines: ...}` the preview
  pane already draws, so `MayonnaiOS.Scene.Home` renders it with the line
  renderer it has rather than a second one.

  ## Where each fact comes from

    * the app version is the OTP release's own, via
      `MayonnaiOS.Update.running_version/0`
    * the firmware line is `Nerves.Runtime.KV`'s active-slot metadata: the
      version fwup stamped and which slot (a or b) is running -- the fact
      that says whether the last update actually took
    * the build is the firmware's fwup UUID, shortened to its first eight
      characters: two devices reading the same eight characters are running
      byte-identical firmware, which no version number can promise
    * uptime is the VM's wall clock -- on this appliance the VM starts
      within seconds of power-on, and a clock the VM owns cannot block
    * the address is the first useful IPv4 the kernel reports, WiFi first
    * memory is what the BEAM has allocated, `:erlang.memory/1` -- the
      number that grows when something in this VM leaks
    * disk free is `MayonnaiOS.Files.space/1` on the writable mounts: the
      data partition, and the games card when it is mounted

  ## Every read is an argument

  Each source is injectable and defaults to the real thing -- the same seam
  `MayonnaiOS.Files`, `MayonnaiOS.Launcher` and `MayonnaiOS.Update` use --
  because a host has no U-Boot environment, no `/root` partition and no
  games card. A fact that cannot be read is a line the panel does not say,
  never a crash: the panel degrades to whatever the machine can answer.
  """

  alias MayonnaiOS.{Files, GamesCard, Update}

  @typedoc "The panel: the shape `MayonnaiOS.Scene.Home`'s info panes draw."
  @type panel :: %{kind: :info, title: String.t(), lines: [String.t()]}

  @doc """
  Build the panel.

  Options, all for tests -- the defaults are what the device uses:

    * `:version` -- `fn -> String.t() end`, default
      `MayonnaiOS.Update.running_version/0`
    * `:kv` -- `fn -> map end` of active-slot firmware metadata plus
      `"nerves_fw_active"`, default `Nerves.Runtime.KV`
    * `:uptime_ms` -- `fn -> non_neg_integer end`, default the VM's wall
      clock
    * `:address` -- `fn -> {interface, address} | nil end`, default the
      kernel's interface list
    * `:memory_bytes` -- `fn -> non_neg_integer end`, default
      `:erlang.memory(:total)`
    * `:space` -- `fn path -> map | nil end`, default
      `MayonnaiOS.Files.space/1`
    * `:data_mount` -- the writable partition's mount point, default
      `"/root"`
    * `:games_mount` -- `fn -> String.t() | nil end`, default
      `MayonnaiOS.GamesCard.mount_point/0`
    * `:games_mounted?` -- `fn -> boolean end`, default
      `MayonnaiOS.GamesCard.mounted?/0`
  """
  @spec panel(keyword()) :: panel()
  def panel(opts \\ []) do
    kv = Keyword.get(opts, :kv, &read_kv/0).()

    lines =
      [
        "MayonnaiOS " <> Keyword.get(opts, :version, &Update.running_version/0).(),
        firmware_line(kv),
        build_line(kv),
        uptime_line(Keyword.get(opts, :uptime_ms, &vm_uptime_ms/0).()),
        address_line(Keyword.get(opts, :address, &first_address/0).()),
        memory_line(Keyword.get(opts, :memory_bytes, &beam_memory/0).())
      ] ++ disk_lines(opts)

    %{kind: :info, title: "This device", lines: Enum.reject(lines, &is_nil/1)}
  end

  # -- firmware ---------------------------------------------------------------

  # Active-slot metadata under its bare names, plus which slot is active.
  # `Nerves.Runtime.KV` already answers with empties when it is not running;
  # the rescue is for a host image without the module at all.
  defp read_kv do
    Nerves.Runtime.KV.get_all_active()
    |> put_present("nerves_fw_active", Nerves.Runtime.KV.get("nerves_fw_active"))
  rescue
    _error -> %{}
  catch
    :exit, _reason -> %{}
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp firmware_line(%{"nerves_fw_version" => version} = kv) when version not in [nil, ""] do
    "firmware #{version}#{slot_words(kv)}"
  end

  defp firmware_line(_kv), do: nil

  defp slot_words(%{"nerves_fw_active" => slot}) when slot not in [nil, ""], do: ", slot #{slot}"
  defp slot_words(_kv), do: ""

  # The first eight characters of the fwup UUID: enough to tell two builds of
  # the same version apart at a glance, short enough to fit the column.
  defp build_line(%{"nerves_fw_uuid" => uuid}) when is_binary(uuid) and byte_size(uuid) >= 8 do
    "build #{String.slice(uuid, 0, 8)}"
  end

  defp build_line(_kv), do: nil

  # -- uptime -----------------------------------------------------------------

  defp vm_uptime_ms do
    {ms, _since_last} = :erlang.statistics(:wall_clock)
    ms
  end

  defp uptime_line(ms) when is_integer(ms) and ms >= 0, do: "up " <> uptime_words(div(ms, 1000))
  defp uptime_line(_reading), do: nil

  # The two largest units that apply: seconds matter in the first minute and
  # never after a day.
  defp uptime_words(s) when s < 60, do: "#{s}s"
  defp uptime_words(s) when s < 3600, do: "#{div(s, 60)}m #{rem(s, 60)}s"
  defp uptime_words(s) when s < 86_400, do: "#{div(s, 3600)}h #{rem(s, 3600) |> div(60)}m"
  defp uptime_words(s), do: "#{div(s, 86_400)}d #{rem(s, 86_400) |> div(3600)}h"

  # -- network ----------------------------------------------------------------

  # One interface and its IPv4, the radio first: on the device wlan0 is the
  # address someone types into a browser to reach the upload page, and usb0
  # only exists while a cable is in.
  defp first_address do
    case :inet.getifaddrs() do
      {:ok, interfaces} ->
        candidates =
          for {name, props} <- interfaces,
              {:addr, {a, _b, _c, _d} = addr} <- props,
              a != 127 do
            {List.to_string(name), addr |> :inet.ntoa() |> List.to_string()}
          end

        Enum.find(candidates, &match?({"wlan" <> _rest, _addr}, &1)) || List.first(candidates)

      {:error, _reason} ->
        nil
    end
  end

  defp address_line(nil), do: "no network address"
  defp address_line({interface, address}), do: "#{interface} #{address}"

  # -- memory -----------------------------------------------------------------

  defp beam_memory, do: :erlang.memory(:total)

  defp memory_line(bytes) when is_integer(bytes), do: "beam memory #{bytes(bytes)}"
  defp memory_line(_reading), do: nil

  # -- disks ------------------------------------------------------------------

  defp disk_lines(opts) do
    space = Keyword.get(opts, :space, &Files.space/1)
    data_mount = Keyword.get(opts, :data_mount, "/root")
    games_mount = Keyword.get(opts, :games_mount, &GamesCard.mount_point/0)
    games_mounted? = Keyword.get(opts, :games_mounted?, &GamesCard.mounted?/0)

    [
      space_line("internal", space.(data_mount)),
      games_line(space, games_mount.(), games_mounted?.())
    ]
  end

  # A mount that cannot be measured is a line the panel does not say.
  defp space_line(_name, nil), do: nil

  defp space_line(name, %{free: free}) do
    "#{name}: #{bytes(free)} free"
  end

  # Only a mounted card gets measured: `df` on an unmounted mount point
  # answers for whatever filesystem the empty directory sits on, and the
  # internal partition's numbers under the card's name would be worse than
  # no line at all.
  defp games_line(_space, nil, _mounted?), do: nil
  defp games_line(space, mount, true), do: space_line("games card", space.(mount))
  defp games_line(_space, _mount, false), do: "games card: not in"

  # -- words ------------------------------------------------------------------

  # Powers of 1024 with df's one-letter units, the units every other number
  # on this panel is quoted in.
  defp bytes(b) when b < 1024, do: "#{b} B"

  defp bytes(b) do
    {value, unit} =
      cond do
        b >= 1024 * 1024 * 1024 -> {b / (1024 * 1024 * 1024), "G"}
        b >= 1024 * 1024 -> {b / (1024 * 1024), "M"}
        true -> {b / 1024, "K"}
      end

    "#{:erlang.float_to_binary(value, decimals: 1)}#{unit}"
  end
end
