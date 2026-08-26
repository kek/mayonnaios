defmodule MayonnaiOS.InputTest do
  use ExUnit.Case, async: true

  alias MayonnaiOS.Input

  # There is no /dev/input on the machine these tests run on, which is the
  # case worth pinning down: a caller that asks for a device by name and is
  # not on the device has to get an answer it cannot mistake for a device, and
  # it must not get one by way of a raise at boot.

  describe "enumerate/0" do
    test "is a list even where there is nothing to enumerate" do
      assert is_list(Input.enumerate())
    end

    test "does not raise on a machine with no input layer" do
      # InputEvent's port binary is only built on Linux, so this call can
      # raise rather than return empty. Whatever it does, it must not escape.
      Input.enumerate()
    end
  end

  describe "find/1" do
    test "is nil when the name is not there, and not a path" do
      # There is nothing to fall back to, on purpose: a fallback runs in
      # exactly the state where the name is absent, and a number reached in
      # that state is some other device that never sends the key being
      # waited for.
      assert Input.find("no-such-device") == nil
    end

    test "a real device name is still nil where there is no input layer" do
      # A laptop, and a device tree that renamed something, get the same
      # answer. Neither of them has the device, and neither is improved by
      # being handed a path to open.
      assert Input.find("gpio-keys-gamepad") == nil
    end
  end

  describe "the paths this app is allowed to know" do
    test "no module hard-codes a numbered input device path" do
      # The regression this test exists for. A quoted `/dev/input/eventN` in
      # `lib/` is a fallback growing back, and a fallback is only ever reached
      # in the state where it names the wrong device: the numbering has moved
      # twice, and each time every number written down in this app was wrong
      # for a firmware or two without anything failing.
      #
      # It looks for the string a caller would pass rather than for the word
      # `event0`, because prose about the numbering is fine and `Input`'s own
      # moduledoc has the table.
      offenders =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.filter(&Regex.match?(~r{"/dev/input/event\d}, File.read!(&1)))

      assert offenders == []
    end
  end

  describe "names/0" do
    test "is a list of path and name pairs" do
      for {path, name} <- Input.names() do
        assert is_binary(path)
        assert is_binary(name)
      end
    end
  end
end
