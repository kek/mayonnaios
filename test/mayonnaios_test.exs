defmodule MayonnaiOSTest do
  use ExUnit.Case

  alias MayonnaiOS.Console

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
    test "matches the panel geometry scenes are laid out for" do
      # A viewport larger than the framebuffer draws off the end of it, and
      # one that differs from MayonnaiOS.Screen leaves scenes laid out for
      # another panel.
      config = Application.get_env(:mayonnaios, :viewport)

      if config do
        assert config[:size] == MayonnaiOS.Screen.size()
        assert config[:size] == Application.fetch_env!(:mayonnaios, :device).panel_size
      end
    end
  end
end
