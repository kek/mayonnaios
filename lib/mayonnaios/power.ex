defmodule MayonnaiOS.Power do
  @moduledoc """
  What the AXP20x power supply says, parsed once for everyone who asks.

  This used to be a private function inside `MayonnaiOS.Diagnostics`, and it
  moved out here when the status bar needed the same four files. A second
  parser reading the same sysfs directory is the kind of duplication that
  ends with two screens disagreeing about the battery and no way to tell
  which one is lying, so there is one, and `Diagnostics` calls it too.

  Verified on hardware, both directions: charge and discharge both move
  `status` and the sign of `current_now`. A sample taken while idle read
  437000 µA at 4175000 µV, which is where the units come from -- microamps
  and microvolts, divided at the point of display and never here.

  ## An unreadable file is not a zero

  `read/1` returns `{:error, :unavailable}` when the supply says nothing at
  all, rather than a map full of zeroes or a remembered value. That
  distinction is the whole reason this module has a return tuple: on a
  development laptop there is no `/sys/class/power_supply`, and a status bar
  that drew "0%" there would be indistinguishable from a flat battery. This
  project's characteristic failure is a plausible reading that never moves,
  so absence is reported as absence.

  `values/1` is the older, flatter shape -- a map whose fields are `nil` for
  whatever could not be read -- kept because the diagnostics screen colours
  each row separately and wants the partial answer.
  """

  # The names are the driver's, not the chip's: mainline binds this PMIC's
  # fuel gauge as axp20x-battery even though the part is an axp2202. Matching
  # on the directory name is what the rest of this project does; see the note
  # about regulator indices in the journal for why matching on a number would
  # be worse.
  @battery "/sys/class/power_supply/axp20x-battery"
  @usb "/sys/class/power_supply/axp20x-usb"

  @type values :: %{
          capacity: non_neg_integer() | nil,
          status: String.t() | nil,
          voltage_uv: integer() | nil,
          current_ua: integer() | nil,
          health: String.t() | nil,
          usb_online: boolean()
        }

  @typedoc """
  What the supply is doing, reduced to the cases a screen draws differently.

  `:unknown` is a real answer and is kept apart from `{:error, :unavailable}`:
  the first is a supply that answered without saying which way the current is
  going, the second is a supply that was not there.
  """
  @type state :: :charging | :discharging | :full | :not_charging | :unknown

  @doc """
  Every field, with `nil` for whatever could not be read.

  Pass `:battery` and `:usb` to read somewhere else; that is what the tests
  do, and it is the only way to exercise a partial or malformed supply
  without a device.
  """
  @spec values(keyword()) :: values()
  def values(opts \\ []) do
    battery = Keyword.get(opts, :battery, @battery)
    usb = Keyword.get(opts, :usb, @usb)

    %{
      capacity: read_int("#{battery}/capacity"),
      status: read_str("#{battery}/status"),
      # Microvolts and microamps; divided for display, not here.
      voltage_uv: read_int("#{battery}/voltage_now"),
      current_ua: read_int("#{battery}/current_now"),
      health: read_str("#{battery}/health"),
      usb_online: read_int("#{usb}/online") == 1
    }
  end

  @doc """
  The supply, or `{:error, :unavailable}` when it said nothing.

  "Nothing" means neither a capacity nor a status: either one on its own is a
  supply that is present and answering, and half an answer is worth drawing
  as long as the missing half is drawn as missing.
  """
  @spec read(keyword()) :: {:ok, values()} | {:error, :unavailable}
  def read(opts \\ []) do
    case values(opts) do
      %{capacity: nil, status: nil} -> {:error, :unavailable}
      values -> {:ok, values}
    end
  end

  @doc """
  Which way the current is going, from the supply's own `status` file.

  The string is the driver's; this maps only the values seen on this board
  and calls anything else `:unknown` rather than guessing from the sign of
  `current_now`. The sign is a fine cross-check and a poor primary source:
  it reads 437000 µA while idle on a battery that is neither charging nor
  discharging in any way a person would recognise.
  """
  @spec state(values() | map()) :: state()
  def state(%{status: "Charging"}), do: :charging
  def state(%{status: "Discharging"}), do: :discharging
  def state(%{status: "Full"}), do: :full
  def state(%{status: "Not charging"}), do: :not_charging
  def state(_values), do: :unknown

  defp read_str(path) do
    case File.read(path) do
      {:ok, v} -> String.trim(v)
      _ -> nil
    end
  end

  defp read_int(path) do
    with v when is_binary(v) <- read_str(path),
         {n, _} <- Integer.parse(v) do
      n
    else
      _ -> nil
    end
  end
end
