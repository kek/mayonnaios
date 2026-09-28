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

  for {file, id} <- [{"config/rg40xxv.exs", :rg40xxv}, {"config/rgsp.exs", :rgsp}] do
    test "the #{id} profile in #{file} is complete and agrees with its viewport" do
      config = Config.Reader.read!(unquote(file))[:mayonnaios]

      Application.put_env(:mayonnaios, :device, config[:device])

      Application.put_env(
        :mayonnaios,
        :viewport,
        Keyword.merge(@host_viewport, config[:viewport])
      )

      assert Device.current!().id == unquote(id)
    end
  end

  test "the RG SP has a lid switch and no stick" do
    config = Config.Reader.read!("config/rgsp.exs")[:mayonnaios]
    Application.put_env(:mayonnaios, :device, config[:device])
    Application.put_env(:mayonnaios, :viewport, Keyword.merge(@host_viewport, config[:viewport]))

    assert Device.current!().panel_size == {720, 480}
    assert Device.input(:stick) == nil
    assert Device.current!().lid_switch == %{device: "gpio-keys-lid", key: :sw_lid}
  end

  test "only optional inputs may be nil" do
    Application.put_env(:mayonnaios, :device, put_in(@host_device, [:inputs, :gamepad], nil))

    assert_raise ArgumentError, ~r/inputs values must be strings/, &Device.current!/0
  end

  defp restore(key, nil), do: Application.delete_env(:mayonnaios, key)
  defp restore(key, value), do: Application.put_env(:mayonnaios, key, value)
end
