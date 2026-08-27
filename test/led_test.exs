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

    test "off darkens both", %{dir: dir} do
      assert Led.set(:off) == :ok
      assert read(dir, @green, "brightness") == "0"
      assert read(dir, @red, "brightness") == "0"
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
