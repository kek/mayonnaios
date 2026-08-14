defmodule ScenicRg40xxvTest do
  use ExUnit.Case

  alias ScenicRg40xxv.Console

  describe "Console on a machine with no framebuffer console" do
    # The host has no /sys/class/vtconsole. These run there, so they pin the
    # fallback path rather than the device behaviour: the console helpers must
    # report failure instead of raising, because they are called from
    # Application.start/2 and an exception there takes the whole node down --
    # which on the device means an unvalidated firmware and a revert.

    test "release/0 reports no fbcon rather than raising" do
      assert Console.release() == {:error, :no_fbcon}
    end

    test "reclaim/0 reports no fbcon rather than raising" do
      assert Console.reclaim() == {:error, :no_fbcon}
    end

    test "bound?/0 is false when there is nothing to be bound to" do
      refute Console.bound?()
    end
  end

  describe "viewport configuration" do
    test "matches the panel geometry" do
      # 640x480 is not a preference. The framebuffer is fixed at that size with
      # a 2560-byte stride, and a mismatch here draws off the end of it.
      config = Application.get_env(:scenic_rg40xxv, :viewport)

      if config do
        assert config[:size] == {640, 480}
      end
    end
  end
end
