defmodule MayonnaiOS.DeviceTest do
  use ExUnit.Case, async: false

  alias MayonnaiOS.Device

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
end
