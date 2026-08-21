defmodule MayonnaiOS.Bluetooth.Advertising do
  @moduledoc """
  The thirty-one bytes a host sees before it has connected to anything.

  An advertising packet is a list of length-tagged structures, and the whole
  budget is 31 bytes. That limit is the only interesting thing about this
  module: the obvious set of fields for a HID gamepad -- flags, appearance,
  the HID service UUID and a readable name -- does not fit, and the failure
  mode for overrunning it is not an error but a controller that refuses the
  command and carries on advertising whatever it had before.

  So the name goes in the scan response instead, which is a second 31 bytes
  the host asks for separately. Every scanning host asks: a device with a
  name only in the scan response still shows up named in Windows' Add-device
  list and in `bluetoothctl`.

  ## What each field is for

  * **Flags** say "LE General Discoverable" and "BR/EDR not supported". The
    second half matters: without it a dual-mode host may try the classic
    transport, find nothing there, and give up rather than falling back.

  * **Appearance** `0x03C4` is Gamepad. This is what puts a controller icon
    next to the device rather than a generic Bluetooth dot, and on Windows it
    is part of how the pairing flow decides the device is an input device.

  * **The service UUID list** carries `0x1812`, the HID service. Hosts filter
    scan results on this: BlueZ's HoG plugin looks for it, and a device that
    only advertises its name has to be connected to before anyone can tell
    what it is.

  There is deliberately no manufacturer-specific data and no TX power. Both
  are bytes that buy nothing here, and bytes are the scarce thing.
  """

  # Common Data Types, from the Assigned Numbers document.
  @ad_flags 0x01
  @ad_incomplete_uuid16 0x02
  @ad_complete_uuid16 0x03
  @ad_short_name 0x08
  @ad_complete_name 0x09
  @ad_appearance 0x19

  # LE General Discoverable Mode, BR/EDR Not Supported.
  @flags 0x06

  @appearance_gamepad 0x03C4
  @uuid_hid 0x1812

  @limit 31

  @doc "Appearance value for a gamepad, `0x03C4`."
  @spec appearance() :: non_neg_integer()
  def appearance, do: @appearance_gamepad

  @doc """
  The advertising data: flags, appearance, and the HID service UUID.

  Eleven bytes of the thirty-one, leaving room for anything a later version
  wants to add without having to think about the budget again.
  """
  @spec data() :: binary()
  def data do
    encode([
      {@ad_flags, <<@flags>>},
      {@ad_appearance, <<@appearance_gamepad::16-little>>},
      {@ad_complete_uuid16, <<@uuid_hid::16-little>>}
    ])
  end

  @doc """
  The scan response: the device name, shortened if it has to be.

  A name longer than the budget is truncated and tagged as a shortened name
  rather than dropped, because the type byte is what tells the host it is
  looking at a prefix. Silently sending a truncated name as a complete one
  gets it cached, by name, in the host's device list.
  """
  @spec scan_response(String.t()) :: binary()
  def scan_response(name) do
    # Two bytes of the structure are its own length and type.
    room = @limit - 2

    if byte_size(name) <= room do
      encode([{@ad_complete_name, name}])
    else
      encode([{@ad_short_name, binary_part(name, 0, room)}])
    end
  end

  @doc """
  Pack a list of `{type, value}` into advertising structures.

  Raises when the result would not fit. This is called with a fixed list at
  startup, so a raise here is a firmware bug that shows up the first time the
  peripheral starts rather than a runtime condition to be handled -- and the
  alternative, truncating, would produce a packet that parses and lies.
  """
  @spec encode([{non_neg_integer(), binary()}]) :: binary()
  def encode(structures) do
    encoded =
      structures
      |> Enum.map(fn {type, value} -> <<byte_size(value) + 1, type, value::binary>> end)
      |> IO.iodata_to_binary()

    if byte_size(encoded) > @limit do
      raise ArgumentError,
            "advertising data is #{byte_size(encoded)} bytes, and the limit is #{@limit}"
    end

    encoded
  end

  @doc """
  Take advertising data apart again, as `{type, value}` in wire order.

  Only used by the tests and by anyone poking at a capture in IEx, but it is
  the honest way to assert on `data/0`: comparing against a hex blob would
  pass just as happily if both were wrong.
  """
  @spec decode(binary()) :: [{non_neg_integer(), binary()}]
  def decode(binary), do: decode(binary, [])

  defp decode(<<>>, acc), do: Enum.reverse(acc)
  # A zero length is the padding at the end of a 31-byte field, not a
  # structure. Everything after it is padding too.
  defp decode(<<0, _rest::binary>>, acc), do: Enum.reverse(acc)

  defp decode(<<length, type, rest::binary>>, acc) when byte_size(rest) >= length - 1 do
    value = binary_part(rest, 0, length - 1)
    remaining = binary_part(rest, length - 1, byte_size(rest) - (length - 1))
    decode(remaining, [{type, value} | acc])
  end

  # A length that runs off the end is a truncated capture; return what parsed.
  defp decode(_truncated, acc), do: Enum.reverse(acc)

  @doc "The AD type numbers, for tests and for reading a decode/1 result."
  @spec types() :: %{atom() => non_neg_integer()}
  def types do
    %{
      flags: @ad_flags,
      incomplete_uuid16: @ad_incomplete_uuid16,
      complete_uuid16: @ad_complete_uuid16,
      short_name: @ad_short_name,
      complete_name: @ad_complete_name,
      appearance: @ad_appearance
    }
  end
end
