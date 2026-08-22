defmodule MayonnaiOS.Bluetooth.Scan do
  @moduledoc """
  A list of what is advertising nearby, built up out of HCI reports.

  Pure functions over `MayonnaiOS.Bluetooth.HCI` advertising reports, in the
  same spirit as the rest of this stack: the socket needs the handheld, but
  everything that can be *wrong* about turning a burst of reports into a
  screenful of devices is a fold over binaries and can be checked on a
  laptop. `MayonnaiOS.Bluetooth.Scanner` is the process that feeds this.

  ## One device is several reports, and that is the whole problem

  An active scan produces at least two reports per device: the
  advertisement, and the scan response that answers the scan request. They
  arrive as separate events, they carry different fields, and only one of
  them usually has the name in it. So merging is not an optimisation here --
  without it, a scan of one pair of headphones produces two rows, one of
  which is nameless.

  Merging is per field, and a field is only overwritten when the new report
  actually carries it. A device that sends a name in its scan response and
  then advertises again without one must not lose the name it already showed;
  `merge/2` therefore takes the new value only when it is not nil. Getting
  that backwards produces a name that flickers on and off at the advertising
  interval, which reads as a radio problem rather than a fold problem.

  ## Ordering is by when it was first seen, never by signal strength

  Sorting by RSSI is the obvious thing and it is wrong for this device. The
  cursor is a D-pad and the list refreshes twice a second; sorting by a
  number that moves means the row under the cursor changes between deciding
  to press A and pressing it. First-seen order is arbitrary but stable, so
  the list only ever grows downwards and a selection stays where it was put.

  ## What "BR/EDR" in the flags is doing here

  Every advertisement may carry a Flags structure, and bit 2 of it is
  "BR/EDR Not Supported" -- the same bit `MayonnaiOS.Bluetooth.Advertising`
  sets on the way out, for the same reason in reverse. Clear, it means the
  device also speaks the classic transport.

  That bit is the honest answer to "why can I see my headphones and not
  connect to them". Bluetooth audio is A2DP, A2DP is BR/EDR, and this
  firmware has no BR/EDR host at all: no BlueZ in the image, and the L2CAP
  here is the three fixed LE channels with no connection-oriented channels
  to carry AVDTP over. So a device advertising with that bit clear is
  reachable-looking and not reachable, and `dual_mode?/1` is what lets the
  screen say so on the row rather than in a footnote.
  """

  import Bitwise

  alias MayonnaiOS.Bluetooth.Advertising

  # Common Data Types, the ones worth reading off a scan. The same numbers
  # Advertising encodes; named again here rather than imported because that
  # module's map is about what this device sends.
  @ad_flags 0x01
  @ad_incomplete_uuid16 0x02
  @ad_complete_uuid16 0x03
  @ad_short_name 0x08
  @ad_complete_name 0x09
  @ad_appearance 0x19

  # Flags bit 2: BR/EDR Not Supported.
  @flag_no_bredr 0x04

  @typedoc "One device, as far as its reports say."
  @type device :: %{
          address: String.t(),
          address_type: 0..3,
          name: String.t() | nil,
          shortened_name?: boolean(),
          flags: non_neg_integer() | nil,
          appearance: non_neg_integer() | nil,
          services: [non_neg_integer()],
          connectable?: boolean(),
          rssi: integer() | nil,
          reports: pos_integer(),
          first_seen: integer(),
          last_seen: integer(),
          sequence: non_neg_integer()
        }

  @typedoc "The accumulated scan."
  @type t :: %__MODULE__{
          devices: %{optional({0..3, String.t()}) => device()},
          next: non_neg_integer()
        }

  defstruct devices: %{}, next: 0

  @doc "An empty scan."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Fold one report in.

  `now` is a monotonic millisecond reading, passed in rather than taken here
  so that a test can advance time without sleeping and so that two reports
  from the same event share one timestamp.
  """
  @spec observe(t(), map(), integer()) :: t()
  def observe(%__MODULE__{} = scan, report, now) do
    key = {report.address_type, report.address}
    fresh = describe(report, now, scan.next)

    case Map.fetch(scan.devices, key) do
      {:ok, existing} ->
        %{scan | devices: Map.put(scan.devices, key, merge(existing, fresh))}

      :error ->
        %{scan | devices: Map.put(scan.devices, key, fresh), next: scan.next + 1}
    end
  end

  @doc "Every device seen, in the order they were first seen."
  @spec list(t()) :: [device()]
  def list(%__MODULE__{devices: devices}) do
    devices |> Map.values() |> Enum.sort_by(& &1.sequence)
  end

  @doc "How many devices are in the list."
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{devices: devices}), do: map_size(devices)

  @doc """
  Drop devices that have not advertised for `stale_ms`.

  Not called on a timer by default. It exists because duplicate filtering is
  off (see `MayonnaiOS.Bluetooth.HCI.le_set_scan_enable/2`), so a device that
  has gone away stops producing reports and its age is the evidence -- and a
  screen is a better place to show that age than to hide it behind a
  disappearing row.
  """
  @spec forget_stale(t(), integer(), pos_integer()) :: t()
  def forget_stale(%__MODULE__{devices: devices} = scan, now, stale_ms) do
    kept = Map.reject(devices, fn {_key, device} -> now - device.last_seen > stale_ms end)
    %{scan | devices: kept}
  end

  @doc """
  Whether this device also speaks the classic transport.

  True when a Flags structure was seen and its "BR/EDR Not Supported" bit is
  clear. `nil` when no Flags structure has arrived yet, which is a different
  thing from "LE only" and is why this is not a boolean: a scan response on
  its own carries no flags, and answering false there would label a pair of
  headphones as LE-only for as long as it took the next advertisement to
  arrive.
  """
  @spec dual_mode?(device()) :: boolean() | nil
  def dual_mode?(%{flags: nil}), do: nil
  def dual_mode?(%{flags: flags}), do: band(flags, @flag_no_bredr) == 0

  @doc "How long ago this device last advertised, in milliseconds."
  @spec age(device(), integer()) :: non_neg_integer()
  def age(device, now), do: max(now - device.last_seen, 0)

  @doc """
  Something to show when a device has no name.

  The address, not "(unknown)": two nameless devices are then still two
  distinguishable rows, and the address is the thing to type into a search
  engine when one of them turns out to be interesting.
  """
  @spec label(device()) :: String.t()
  def label(%{name: nil, address: address}), do: address
  def label(%{name: name}), do: name

  # -- turning one report into one device -------------------------------------

  defp describe(report, now, sequence) do
    structures = Advertising.decode(report.data)

    %{
      address: report.address,
      address_type: report.address_type,
      name: name_of(structures),
      shortened_name?:
        has?(structures, @ad_short_name) and not has?(structures, @ad_complete_name),
      flags: first_byte(structures, @ad_flags),
      appearance: uuid16(structures, @ad_appearance),
      services: services(structures),
      connectable?: report.event_type in [:adv_ind, :adv_direct_ind],
      rssi: report.rssi,
      reports: 1,
      first_seen: now,
      last_seen: now,
      sequence: sequence
    }
  end

  # The merge rule, stated once: identity and firsts come from the old
  # record, counters accumulate, and every descriptive field is taken from
  # the new one only if the new one has it.
  defp merge(old, new) do
    %{
      old
      | name: new.name || old.name,
        shortened_name?: if(new.name, do: new.shortened_name?, else: old.shortened_name?),
        flags: new.flags || old.flags,
        appearance: new.appearance || old.appearance,
        services: if(new.services == [], do: old.services, else: new.services),
        # Connectability is sticky in one direction. A scan response is
        # reported with its own event type, so a device that advertised
        # ADV_IND and then answered a scan request would otherwise be
        # downgraded to unconnectable by its own reply.
        connectable?: old.connectable? or new.connectable?,
        rssi: new.rssi || old.rssi,
        reports: old.reports + 1,
        last_seen: new.last_seen
    }
  end

  # A complete name wins over a shortened one when both are somehow present.
  defp name_of(structures) do
    with nil <- value(structures, @ad_complete_name),
         nil <- value(structures, @ad_short_name) do
      nil
    else
      # Names are UTF-8 on the wire and a device is free to send something
      # that is not. Printing raw bytes into a Scenic text primitive is how a
      # scene crashes on a stranger's kettle, so anything invalid is dropped
      # back to nil and the row falls through to showing the address.
      name -> if String.valid?(name), do: name
    end
  end

  defp services(structures) do
    (list16(structures, @ad_complete_uuid16) ++ list16(structures, @ad_incomplete_uuid16))
    |> Enum.uniq()
  end

  defp value(structures, type) do
    Enum.find_value(structures, fn
      {^type, value} -> value
      _ -> nil
    end)
  end

  defp has?(structures, type), do: value(structures, type) != nil

  defp first_byte(structures, type) do
    case value(structures, type) do
      <<byte, _rest::binary>> -> byte
      _ -> nil
    end
  end

  defp uuid16(structures, type) do
    case value(structures, type) do
      <<uuid::16-little>> -> uuid
      _ -> nil
    end
  end

  defp list16(structures, type) do
    case value(structures, type) do
      nil -> []
      binary -> for <<uuid::16-little <- binary>>, do: uuid
    end
  end
end
