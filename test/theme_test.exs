defmodule MayonnaiOS.ThemeTest do
  use ExUnit.Case, async: false

  alias MayonnaiOS.Theme
  alias Scenic.Assets.Static

  # Theme selection lives in a :persistent_term (see the module for why), so
  # it outlives every test process. Every test here resets it on the way
  # out -- a theme picked in one test leaking into the next would be exactly
  # the kind of bug this module exists to make impossible for scenes.
  setup do
    on_exit(fn -> Theme.set(:default) end)
    :ok
  end

  describe "current/0" do
    test "is :default before anything has been chosen" do
      assert Theme.current().name == :default
    end

    test "reflects the last theme set/1 chose" do
      Theme.set(:synthwave)
      assert Theme.current().name == :synthwave
    end
  end

  describe "set/1" do
    test "accepts every name names/0 lists" do
      for name <- Theme.names() do
        assert Theme.set(name) == :ok
        assert Theme.current().name == name
      end
    end

    test "rejects an unknown name and leaves the current theme alone" do
      Theme.set(:c64)
      assert Theme.set(:not_a_theme) == :error
      assert Theme.current().name == :c64
    end
  end

  describe "cycle/0" do
    test "advances through every built-in theme and wraps" do
      assert Theme.current().name == :default

      for name <- [:c64, :synthwave, :default] do
        assert Theme.cycle() == name
        assert Theme.current().name == name
      end
    end
  end

  describe "by_name/1 and default/0" do
    test "by_name finds every built-in theme" do
      for name <- Theme.names() do
        assert {:ok, %Theme{name: ^name}} = Theme.by_name(name)
      end
    end

    test "by_name/1 misses an unknown name" do
      assert Theme.by_name(:not_a_theme) == :error
    end

    test "default/0 is the :default theme regardless of what is selected" do
      Theme.set(:c64)
      assert Theme.default().name == :default
    end
  end

  describe "every built-in theme" do
    test "uses Pixel Operator as the body font" do
      for name <- Theme.names() do
        {:ok, theme} = Theme.by_name(name)
        assert theme.font == :pixel_operator
      end
    end

    test "carries a font, a title font, and every chrome colour" do
      for name <- Theme.names() do
        {:ok, theme} = Theme.by_name(name)

        assert is_atom(theme.font)
        assert is_atom(theme.title_font)

        for field <- [:bg, :bar_bg, :title, :head, :label, :pass, :fail, :wait, :dim, :row_bg] do
          assert {r, g, b} = Map.fetch!(theme, field)
          assert r in 0..255 and g in 0..255 and b in 0..255
        end
      end
    end

    test "keeps the semantic colours -- pass, fail, wait -- identical across themes" do
      # A red \"fail\" that turned some other colour because a theme wanted a
      # matching palette would be recolouring what the colour means, not the
      # chrome around it. See the moduledoc.
      themes = for name <- Theme.names(), do: elem(Theme.by_name(name), 1)

      for field <- [:pass, :fail, :wait] do
        assert themes |> Enum.map(&Map.fetch!(&1, field)) |> Enum.uniq() |> length() == 1
      end
    end
  end

  describe "width/2 and width/3" do
    test "Pixel Operator is registered as a real Scenic font asset" do
      assert {:ok, {Static.Font, _metrics}} = Static.meta(:pixel_operator)
    end

    test "measures known text as wider than nothing" do
      assert Theme.width("System", 16) > 0
      assert Theme.width("", 16) == 0
    end

    test "a fixed string in the title font is narrower than the same string set larger" do
      small = Theme.width("Delete this?", 16, :press_start_2p)
      large = Theme.width("Delete this?", 32, :press_start_2p)
      assert large > small
    end
  end
end
