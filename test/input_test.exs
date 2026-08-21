defmodule MayonnaiOS.InputTest do
  use ExUnit.Case, async: true

  alias MayonnaiOS.Input

  # There is no /dev/input on the machine these tests run on, which is the
  # case worth pinning down: the fallback has to be what a caller gets when
  # enumeration cannot happen at all, because that is the difference between
  # "the launcher opens the path it always did" and "the launcher crashes at
  # boot looking for its buttons".

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

  describe "find/2" do
    test "falls back to the given path when the name is not there" do
      assert Input.find("no-such-device", "/dev/input/event0") == "/dev/input/event0"
    end

    test "the fallback is returned verbatim, not normalised or checked" do
      # Deliberately not File.exists?/1: the caller's job is to open it and
      # handle the failure, and a find/2 that returned nil for a missing path
      # would make every call site handle two kinds of nothing.
      assert Input.find("no-such-device", "/tmp/not-a-device") == "/tmp/not-a-device"
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
