defmodule MayonnaiOS.LedTest do
  use ExUnit.Case, async: false

  alias MayonnaiOS.Led

  # The LEDs are files, which is what makes this testable on a laptop: `Led`
  # writes triggers and delays into a directory of sysfs attributes, so
  # pointing :leds_class at a temp directory exercises the same code path the
  # device runs. What no test can check is which color each name shines --
  # that mapping is in the moduledoc, and only eyes on the device confirm it.

  @green "green:power"
  @red "green:status"

  setup do
    dir = Path.join(System.tmp_dir!(), "leds-#{System.unique_integer([:positive])}")

    for led <- [@green, @red] do
      File.mkdir_p!(Path.join(dir, led))
    end

    Application.put_env(:mayonnaios, :leds_class, dir)

    on_exit(fn ->
      Application.delete_env(:mayonnaios, :leds_class)
      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  defp read(dir, led, file), do: File.read!(Path.join([dir, led, file]))

  describe "each state" do
    test "starting flashes green quickly and darkens red", %{dir: dir} do
      assert Led.set(:starting) == :ok
      assert read(dir, @green, "trigger") == "timer"
      assert read(dir, @green, "delay_on") == "100"
      assert read(dir, @green, "delay_off") == "100"
      assert read(dir, @red, "trigger") == "none"
      assert read(dir, @red, "brightness") == "0"
    end

    test "running holds green solid and darkens red", %{dir: dir} do
      assert Led.set(:running) == :ok
      assert read(dir, @green, "trigger") == "none"
      assert read(dir, @green, "brightness") == "1"
      assert read(dir, @red, "brightness") == "0"
    end

    test "sleeping flashes green slowly", %{dir: dir} do
      assert Led.set(:sleeping) == :ok
      assert read(dir, @green, "trigger") == "timer"
      assert read(dir, @green, "delay_on") == "1000"
      assert read(dir, @green, "delay_off") == "1000"
      assert read(dir, @red, "brightness") == "0"
    end

    test "failure blinks red and darkens green", %{dir: dir} do
      assert Led.set(:failure) == :ok
      assert read(dir, @red, "trigger") == "timer"
      assert read(dir, @red, "delay_on") == "250"
      assert read(dir, @red, "delay_off") == "250"
      assert read(dir, @green, "trigger") == "none"
      assert read(dir, @green, "brightness") == "0"
    end

    test "low battery blinks red more slowly than failure", %{dir: dir} do
      assert Led.set(:low_battery) == :ok
      assert read(dir, @red, "trigger") == "timer"
      assert read(dir, @red, "delay_on") == "1000"
      assert read(dir, @red, "delay_off") == "1000"
      assert read(dir, @green, "brightness") == "0"
    end

    test "off darkens both", %{dir: dir} do
      assert Led.set(:off) == :ok
      assert read(dir, @green, "brightness") == "0"
      assert read(dir, @red, "brightness") == "0"
    end
  end

  describe "battery arbitration" do
    test "enters at 20 percent, holds through hysteresis, and clears at 30", %{dir: dir} do
      start_supervised!({Led.Monitor, status: nil})
      assert Led.set(:running) == :ok

      battery(20, "Discharging")
      assert read(dir, @red, "delay_on") == "1000"
      assert :sys.get_state(Led.Monitor).low_battery

      battery(25, "Discharging")
      assert :sys.get_state(Led.Monitor).low_battery
      assert read(dir, @red, "delay_on") == "1000"

      battery(30, "Discharging")
      refute :sys.get_state(Led.Monitor).low_battery
      assert read(dir, @green, "brightness") == "1"
      assert read(dir, @red, "brightness") == "0"
    end

    test "charging and unavailable readings clear low battery", %{dir: dir} do
      start_supervised!({Led.Monitor, status: nil})
      Led.set(:sleeping)

      battery(10, "Not charging")
      assert :sys.get_state(Led.Monitor).low_battery

      battery(10, "Charging")
      refute :sys.get_state(Led.Monitor).low_battery
      assert read(dir, @green, "delay_on") == "1000"

      battery(10, "Discharging")
      assert :sys.get_state(Led.Monitor).low_battery

      send(Led.Monitor, {:mayonnaios_status, %{battery: %{value: nil, error: :unavailable}}})
      refute :sys.get_state(Led.Monitor).low_battery
      assert read(dir, @green, "delay_on") == "1000"
    end

    test "failure outranks low battery", %{dir: dir} do
      start_supervised!({Led.Monitor, status: nil})
      Led.set(:running)
      battery(5, "Discharging")

      assert Led.set(:failure) == :ok
      assert read(dir, @red, "delay_on") == "250"
      assert read(dir, @red, "delay_off") == "250"

      battery(4, "Discharging")
      assert read(dir, @red, "delay_on") == "250"
      assert :sys.get_state(Led.Monitor).drawn == :failure
    end

    defp battery(capacity, status) do
      send(
        Led.Monitor,
        {:mayonnaios_status,
         %{battery: %{value: %{capacity: capacity, status: status}, error: nil}}}
      )

      :sys.get_state(Led.Monitor)
    end
  end

  describe "states overwrite each other" do
    test "failure after running leaves no green behind", %{dir: dir} do
      assert Led.set(:running) == :ok
      assert Led.set(:failure) == :ok
      assert read(dir, @green, "brightness") == "0"
      assert read(dir, @red, "trigger") == "timer"
    end

    test "waking from sleep restores solid green", %{dir: dir} do
      assert Led.set(:sleeping) == :ok
      assert Led.set(:running) == :ok
      assert read(dir, @green, "trigger") == "none"
      assert read(dir, @green, "brightness") == "1"
    end
  end

  describe "a laptop with no LEDs" do
    test "is ordinary, not an error" do
      Application.put_env(
        :mayonnaios,
        :leds_class,
        Path.join(System.tmp_dir!(), "absent-#{System.unique_integer([:positive])}")
      )

      assert Led.set(:running) == :ok
    end
  end

  describe "a directory that refuses the write" do
    test "returns the error and still writes the other emitter", %{dir: dir} do
      # The red LED's directory goes missing while the green one stays: the
      # error comes back, and green is written anyway rather than left in the
      # previous state.
      File.rm_rf!(Path.join(dir, @red))
      assert {:error, :enoent} = Led.set(:running)
      assert read(dir, @green, "brightness") == "1"
    end
  end
end
