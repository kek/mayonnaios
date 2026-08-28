defmodule MayonnaiOS.WiFi.EditorTest do
  # Async: a map and pure functions, no process and no globals.
  use ExUnit.Case, async: true

  alias MayonnaiOS.WiFi.Editor

  defp press(editor, button) do
    {:editing, editor} = Editor.input(editor, button)
    editor
  end

  defp pressed(editor, buttons), do: Enum.reduce(buttons, editor, &press(&2, &1))

  # Type a string the way somebody holding the device would: cycle the wheel
  # to a character, move the caret right, cycle to the next. Moving is the
  # part that adds a position -- see the test below that pins that down --
  # so a helper that only pressed a direction would type one character and
  # spin it.
  defp type(editor, string) do
    string
    |> String.graphemes()
    |> Enum.reduce(editor, fn char, acc -> acc |> wheel_to(char) |> press(:right) end)
  end

  defp wheel_to(editor, char) do
    Enum.reduce_while(1..length(Editor.alphabet()), press(editor, :down), fn _n, acc ->
      if Editor.current(acc) == char, do: {:halt, acc}, else: {:cont, press(acc, :down)}
    end)
  end

  describe "the wheel" do
    test "is every printable ASCII character, exactly once" do
      # A passphrase is somebody else's string, chosen for a router. An
      # alphabet quietly missing `#` is a screen that cannot join a real
      # network and does not say so.
      wheel = MapSet.new(Editor.alphabet())
      printable = MapSet.new(for code <- 32..126, do: <<code>>)

      assert wheel == printable
      assert length(Editor.alphabet()) == 95
      assert length(Enum.uniq(Editor.alphabet())) == 95
    end

    test "starts at the lowercase letters, which is what a passphrase mostly is" do
      assert hd(Editor.alphabet()) == "a"
    end
  end

  describe "new/1" do
    test "is empty, with the caret at the front" do
      editor = Editor.new("kitchen")

      assert editor.ssid == "kitchen"
      assert Editor.value(editor) == ""
      assert Editor.length(editor) == 0
      assert editor.caret == 0
      assert Editor.current(editor) == nil
    end
  end

  describe "step/2" do
    test "the first press past the end adds a character and leaves the caret on it" do
      editor = Editor.step(Editor.new("x"), +1)

      assert Editor.value(editor) == "a"
      assert editor.caret == 0
    end

    test "pressing the same direction again steps that character rather than adding one" do
      # The property the typing helper above is built around, and the
      # browser's rename editor behaves the same way: a position is added by
      # moving the caret, not by picking another character.
      editor = pressed(Editor.new("x"), [:down, :down, :down])

      assert Editor.value(editor) == "c"
      assert Editor.length(editor) == 1
    end

    test "the other direction starts at the far end of the wheel" do
      assert Editor.value(Editor.step(Editor.new("x"), -1)) == "~"
    end

    test "wraps around the wheel rather than stopping at either end" do
      editor = Editor.new("x") |> Editor.step(+1) |> Editor.step(-1)

      assert Editor.value(editor) == "~"
    end

    test "changes the character under the caret, not the last one" do
      editor = Editor.new("x") |> type("abc") |> Editor.move(-3)

      assert Editor.value(editor) == "abc"
      assert Editor.value(Editor.step(editor, +1)) == "bbc"
    end
  end

  describe "move/2" do
    test "is bounded rather than wrapping" do
      # The two ends mean something: the front is where a character was
      # mistyped and the end is where the next one goes. A caret that wrapped
      # would send someone who pressed right once too often back to the start
      # of a passphrase they are in the middle of.
      editor = Editor.new("x") |> type("ab")

      assert Editor.move(editor, -5).caret == 0
      assert Editor.move(editor, +5).caret == 2
    end

    test "the caret may sit one past the last character" do
      editor = Editor.new("x") |> type("a")

      assert editor.caret == 1
      assert Editor.current(editor) == nil
    end
  end

  describe "jump/2" do
    test "moves the character under the caret to the head of the next block" do
      editor = Editor.new("x") |> Editor.jump(+1)
      assert Editor.value(editor) == "a"

      editor = Editor.jump(editor, +1)
      assert Editor.value(editor) == "A"

      editor = Editor.jump(editor, +1)
      assert Editor.value(editor) == "0"

      editor = Editor.jump(editor, +1)
      assert Editor.value(editor) == " "

      # Four blocks, so the fifth jump is back to the first.
      assert Editor.value(Editor.jump(editor, +1)) == "a"
    end

    test "backwards from the first block wraps to the last" do
      editor = Editor.new("x") |> Editor.jump(+1)

      assert Editor.value(Editor.jump(editor, -1)) == " "
    end

    test "from nothing the two directions take the two ends" do
      assert Editor.value(Editor.jump(Editor.new("x"), +1)) == "a"
      assert Editor.value(Editor.jump(Editor.new("x"), -1)) == " "
    end

    test "a jump lands on a block head, not on the same offset in the next block" do
      editor = Editor.new("x") |> type("abcd") |> Editor.move(-2)

      assert Editor.current(editor) == "c"
      assert Editor.value(Editor.jump(editor, +1)) == "abAd"
    end

    test "getting to an uppercase letter is a jump and a few presses" do
      # The reason the shoulder buttons exist: ninety-five characters is up
      # to ninety-four presses of one direction.
      editor = pressed(Editor.new("x"), [:r1, :r1])

      assert Editor.value(editor) == "A"
      assert Editor.value(pressed(editor, [:down, :down])) == "C"
    end
  end

  describe "drop/1" do
    test "removes the character under the caret" do
      editor = Editor.new("x") |> type("abc") |> Editor.move(-3) |> Editor.drop()

      assert Editor.value(editor) == "bc"
      assert editor.caret == 0
    end

    test "past the end it removes the last character" do
      editor = Editor.new("x") |> type("ab")

      assert editor.caret == 2
      assert Editor.value(Editor.drop(editor)) == "a"
    end

    test "on an empty passphrase it does nothing" do
      assert Editor.drop(Editor.new("x")) == Editor.new("x")
    end

    test "the caret never ends up past the end of what is left" do
      editor = Editor.new("x") |> type("a") |> Editor.drop()

      assert Editor.value(editor) == ""
      assert editor.caret == 0
    end
  end

  describe "input/2" do
    test "the D-pad works the wheel and the caret" do
      editor = Editor.new("kitchen")

      assert {:editing, %{chars: ["a"]}} = Editor.input(editor, :down)
      assert {:editing, %{chars: ["~"]}} = Editor.input(editor, :up)
      assert {:editing, %{caret: 0}} = Editor.input(editor, :left)
      assert {:editing, %{caret: 1}} = Editor.input(type(editor, "a"), :right)
    end

    test "the shoulders jump blocks" do
      editor = Editor.new("kitchen")

      assert {:editing, %{chars: ["a"]}} = Editor.input(editor, :r1)
      assert {:editing, %{chars: [" "]}} = Editor.input(editor, :l1)
    end

    test "Y removes, the same button it removes with in the rename editor" do
      editor = Editor.new("x") |> type("ab")

      assert {:editing, dropped} = Editor.input(editor, :y)
      assert Editor.value(dropped) == "a"
    end

    test "A is done and hands back what was picked" do
      editor = Editor.new("x") |> type("ab")

      assert Editor.input(editor, :a) == {:done, "ab"}
    end

    test "A hands back a passphrase too short to be accepted" do
      # The length rule belongs to `MayonnaiOS.WiFi`, which says so on the
      # panel. A picker that silently swallowed A would look broken.
      assert Editor.input(Editor.new("x"), :a) == {:done, ""}
    end

    test "B gives up" do
      assert Editor.input(Editor.new("x"), :b) == :cancelled
    end

    test "anything it has no use for leaves it alone" do
      editor = Editor.new("x") |> type("a")

      assert {:editing, ^editor} = Editor.input(editor, :x)
      assert {:editing, ^editor} = Editor.input(editor, :start)
    end
  end

  test "a real passphrase, with symbols and capitals, comes back as it was picked" do
    passphrase = "Correct-Horse 42!"

    editor = Editor.new("kitchen") |> type(passphrase)

    assert Editor.value(editor) == passphrase
    assert Editor.length(editor) == String.length(passphrase)
  end

  test "a full-length passphrase fits" do
    # Sixty-three characters is WPA's maximum, and two lines on the panel.
    editor = Editor.new("kitchen") |> type(String.duplicate("a", 63))

    assert Editor.length(editor) == 63
    assert Editor.value(editor) == String.duplicate("a", 63)
  end
end
