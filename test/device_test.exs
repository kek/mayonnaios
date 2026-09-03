defmodule MayonnaiOS.DeviceTest do
  use ExUnit.Case, async: false

  alias MayonnaiOS.Device

  @host_device Application.compile_env!(:mayonnaios, :device)
  @host_viewport Application.compile_env!(:mayonnaios, :viewport)

  setup do
    previous_device = Application.get_env(:mayonnaios, :device)
    previous_viewport = Application.get_env(:mayonnaios, :viewport)

    Application.put_env(:mayonnaios, :device, @host_device)
    Application.put_env(:mayonnaios, :viewport, @host_viewport)

    on_exit(fn ->
      restore(:device, previous_device)
      restore(:viewport, previous_viewport)
    end)
  end

  test "the host profile is complete and agrees with the viewport" do
    profile = Device.current!()

    assert profile.id == :host
    assert profile.panel_size == {640, 480}
    assert profile.panel_size == get_in(Application.fetch_env!(:mayonnaios, :viewport), [:size])
    assert Device.input(:gamepad) == "host-gamepad"
    assert Device.button(:launch) == :btn_b
    assert profile.lid_switch == nil
    assert profile.rtc?
  end

  test "an incomplete profile fails with the missing hardware facts named" do
    previous = Application.fetch_env!(:mayonnaios, :device)
    Application.put_env(:mayonnaios, :device, Map.delete(previous, :buttons))
    on_exit(fn -> Application.put_env(:mayonnaios, :device, previous) end)

    assert_raise ArgumentError, ~r/keys must also be given.*:buttons/, &Device.current!/0
  end

  test "a profile cannot disagree with the configured viewport" do
    previous = Application.fetch_env!(:mayonnaios, :device)
    Application.put_env(:mayonnaios, :device, %{previous | panel_size: {320, 240}})
    on_exit(fn -> Application.put_env(:mayonnaios, :device, previous) end)

    assert_raise ArgumentError, ~r/does not match viewport/, &Device.current!/0
  end

  defp restore(key, nil), do: Application.delete_env(:mayonnaios, key)
  defp restore(key, value), do: Application.put_env(:mayonnaios, key, value)
end
