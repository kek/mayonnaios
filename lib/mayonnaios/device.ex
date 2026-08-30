defmodule MayonnaiOS.Device do
  @moduledoc """
  The hardware facts for the device running MayonnaiOS.

  A profile is configuration, not target detection. `MIX_TARGET` selects the
  system that can boot a board; that target's config supplies the names and
  mappings the application needs once it is running. Keeping those facts in
  one validated struct prevents a missing key from degrading into a button or
  LED that silently does nothing.
  """

  require Logger

  @button_keys [
    :launch,
    :confirm,
    :actions,
    :full,
    :poweroff_modifier,
    :home,
    :up,
    :down,
    :left,
    :right,
    :page_up,
    :page_down,
    :back,
    :sleep
  ]
  @input_keys [:gamepad, :stick, :volume, :headphone, :power]

  @enforce_keys [
    :id,
    :name,
    :panel_size,
    :inputs,
    :buttons,
    :leds,
    :power_supplies,
    :games_card_device,
    :backlight,
    :lid_switch,
    :rtc?
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: atom(),
          name: String.t(),
          panel_size: {pos_integer(), pos_integer()},
          inputs: %{required(atom()) => String.t()},
          buttons: %{required(atom()) => atom()},
          leds: %{green: String.t(), red: String.t()},
          power_supplies: %{battery: String.t(), usb: String.t()},
          games_card_device: String.t(),
          backlight: String.t(),
          lid_switch: nil | %{device: String.t(), key: atom()},
          rtc?: boolean()
        }

  @doc "Read and validate the configured profile."
  @spec current!() :: t()
  def current! do
    :mayonnaios
    |> Application.fetch_env!(:device)
    |> then(&struct!(__MODULE__, &1))
    |> validate!()
  end

  @doc false
  def load! do
    profile = current!()

    Logger.info(
      "[device] #{profile.name} (#{profile.id}), #{format_size(profile.panel_size)}, " <>
        "RTC #{present(profile.rtc?)}, lid switch #{present(profile.lid_switch != nil)}"
    )

    profile
  end

  @doc "Return one semantic button's evdev atom."
  @spec button(atom()) :: atom()
  def button(semantic), do: Map.fetch!(current!().buttons, semantic)

  @doc "Return one input device's device-tree name."
  @spec input(atom()) :: String.t()
  def input(kind), do: Map.fetch!(current!().inputs, kind)

  defp validate!(profile) do
    require_keys!(profile.inputs, @input_keys, :inputs)
    require_keys!(profile.buttons, @button_keys, :buttons)
    require_keys!(profile.leds, [:green, :red], :leds)
    require_keys!(profile.power_supplies, [:battery, :usb], :power_supplies)

    unless is_atom(profile.id) and is_binary(profile.name) and profile.name != "" do
      raise ArgumentError, "device :id must be an atom and :name must be a non-empty string"
    end

    unless match?(
             {width, height}
             when is_integer(width) and width > 0 and is_integer(height) and height > 0,
             profile.panel_size
           ) do
      raise ArgumentError, "device :panel_size must contain two positive integers"
    end

    require_values!(profile.inputs, &is_binary/1, :inputs, "strings")
    require_values!(profile.buttons, &is_atom/1, :buttons, "atoms")
    require_values!(profile.leds, &is_binary/1, :leds, "strings")
    require_values!(profile.power_supplies, &is_binary/1, :power_supplies, "strings")

    unless is_binary(profile.games_card_device) and is_binary(profile.backlight) and
             is_boolean(profile.rtc?) do
      raise ArgumentError,
            "device paths must be strings and :rtc? must be a boolean"
    end

    unless is_nil(profile.lid_switch) or
             match?(
               %{device: device, key: key} when is_binary(device) and is_atom(key),
               profile.lid_switch
             ) do
      raise ArgumentError, "device :lid_switch must be nil or %{device: string, key: atom}"
    end

    viewport_size = get_in(Application.get_env(:mayonnaios, :viewport, []), [:size])

    if viewport_size && viewport_size != profile.panel_size do
      raise ArgumentError,
            "device panel #{inspect(profile.panel_size)} does not match viewport #{inspect(viewport_size)}"
    end

    profile
  end

  defp require_keys!(map, keys, field) when is_map(map) do
    case Enum.reject(keys, &Map.has_key?(map, &1)) do
      [] -> :ok
      missing -> raise ArgumentError, "device #{field} missing #{inspect(missing)}"
    end
  end

  defp require_keys!(_value, _keys, field),
    do: raise(ArgumentError, "device #{field} must be a map")

  defp require_values!(map, predicate, field, expected) do
    unless Enum.all?(Map.values(map), predicate) do
      raise ArgumentError, "device #{field} values must be #{expected}"
    end
  end

  defp format_size({width, height}), do: "#{width}x#{height}"
  defp present(true), do: "present"
  defp present(false), do: "absent"
end
