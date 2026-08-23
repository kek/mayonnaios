defmodule MayonnaiOS.Pickles.FrameTest do
  use ExUnit.Case, async: true

  alias MayonnaiOS.Pickles.Frame

  # These maps are what a Lua display list looks like after decoding: string
  # keys, numbers that may be floats, anything at all where the script made a
  # mistake.

  describe "build/1" do
    test "validates each kind of op" do
      %{ops: ops, invalid: 0} =
        Frame.build([
          %{"kind" => "text", "x" => 10, "y" => 20.7, "text" => "hi"},
          %{"kind" => "rect", "x" => 0, "y" => 0, "w" => 640, "h" => 480, "color" => "black"},
          %{"kind" => "line", "x1" => 0, "y1" => 1, "x2" => 2, "y2" => 3, "width" => 2},
          %{"kind" => "circle", "x" => 320, "y" => 240, "r" => 24, "fill" => false}
        ])

      assert [
               {:text, %{x: 10, y: 20, text: "hi", size: 16, color: :white}},
               {:rect, %{w: 640, h: 480, color: :black, fill: true}},
               {:line, %{x1: 0, y1: 1, x2: 2, y2: 3, width: 2}},
               {:circle, %{r: 24, fill: false, color: :white}}
             ] = ops
    end

    test "counts what it cannot draw instead of dropping it silently" do
      %{ops: ops, invalid: 2} =
        Frame.build([
          %{"kind" => "text", "x" => 1, "y" => 2, "text" => "kept"},
          %{"kind" => "text", "x" => "not a number", "y" => 2, "text" => "lost"},
          %{"kind" => "hexagon", "x" => 1, "y" => 2}
        ])

      assert [{:text, %{text: "kept"}}] = ops
    end

    test "a non-list is a frame that says so" do
      assert %{ops: [], invalid: 1} = Frame.build("not a list")
      assert %{ops: [], invalid: 1} = Frame.build(nil)
    end

    test "unknown colors fall back to white rather than crashing the frame" do
      %{ops: [{:text, %{color: :white}}], invalid: 0} =
        Frame.build([
          %{"kind" => "text", "x" => 1, "y" => 2, "text" => "t", "color" => "#ff00ff"}
        ])
    end

    test "sizes are clamped, text is capped, op count is capped" do
      %{ops: [{:text, op}], invalid: 0} =
        Frame.build([
          %{
            "kind" => "text",
            "x" => 1,
            "y" => 2,
            "text" => String.duplicate("a", 1000),
            "size" => 100_000
          }
        ])

      assert op.size == 200
      assert String.length(op.text) == 200

      many = List.duplicate(%{"kind" => "circle", "x" => 1, "y" => 2, "r" => 3}, 300)
      %{ops: ops, invalid: 44} = Frame.build(many)
      assert length(ops) == 256
    end
  end

  describe "button_name/1" do
    test "speaks the names on the plastic, swaps and all" do
      # Linux calls the physical A button :btn_b on this layout; the whole
      # point of this function is that no script author meets that fact.
      assert Frame.button_name(:btn_b) == "a"
      assert Frame.button_name(:btn_a) == "b"
      assert Frame.button_name(:btn_y) == "x"
      assert Frame.button_name(:btn_x) == "y"
      assert Frame.button_name(:btn_dpad_up) == "up"
      assert Frame.button_name(:btn_tl) == "l1"
      assert Frame.button_name(:btn_start) == "start"
    end

    test "menu and strangers are nobody's button" do
      assert Frame.button_name(:btn_mode) == nil
      assert Frame.button_name(:key_power) == nil
    end
  end
end
