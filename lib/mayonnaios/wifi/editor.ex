defmodule MayonnaiOS.WiFi.Editor do
  @moduledoc """
  Typing a WiFi passphrase on a device with no keyboard: a character wheel
  under a caret, moved with the D-pad.

      left / right   move the caret
      up / down      change the character under it
      L1 / R1        jump to the next or previous block of characters
      Y              remove the character under the caret
      A              done
      B              give up

  The same picker `MayonnaiOS.Browser`'s rename editor is, and for the same
  reason: the alternative is a settings screen that can only be reached over
  SSH, which is a settings screen for the one situation -- no network -- it
  exists to fix.

  ## The alphabet is all of printable ASCII, and that is why L1 and R1 exist

  A filename picker can get away with sixty-odd characters because the names
  on this device are ROMs and directories. A passphrase cannot: it is
  somebody else's string, chosen for a router, and `wpa_supplicant` takes any
  of the 95 printable ASCII characters. An alphabet that quietly omitted `#`
  would be a screen that cannot join a real network and does not say so.

  Ninety-five characters is up to ninety-four presses of one direction, so
  the wheel is ordered in four blocks -- lowercase, uppercase, digits,
  symbols -- and the shoulder buttons jump between them. Getting to `Q` is
  then R1 and a few presses of up rather than a held direction and a count.
  Blocks are also why the order is not ASCII's: ASCII puts the symbols in
  three separate runs around the digits and letters, which is four jumps to
  cross what is conceptually one block.

  ## The passphrase is shown, not masked

  Nothing here is picked blind. Every character is chosen by cycling a wheel
  that has to be read to be used, so a mask would hide the string from the
  one person who is already looking at each character as it is chosen -- and
  make a mistake made twenty presses ago unfindable. The device is in one
  person's hands at arm's length; that is a different threat model from a
  login box on a shared screen.

  ## No process and no state of its own

  A map and pure functions, like `MayonnaiOS.Browser`. `MayonnaiOS.WiFi.App`
  holds one in its state, so the caret survives the scene being torn down and
  rebuilt by `Scenic.ViewPort.set_root/3` -- which is the same reason the
  browser's cursor does not live in a scene.
  """

  @lower String.graphemes("abcdefghijklmnopqrstuvwxyz")
  @upper String.graphemes("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
  @digits String.graphemes("0123456789")
  # Every printable ASCII character that is not a letter or a digit, space
  # included -- a passphrase may contain one and there is no other way to
  # enter it. Gathered into one block rather than left where ASCII puts them.
  @symbols String.graphemes(" !\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")

  @blocks [@lower, @upper, @digits, @symbols]
  @alphabet Enum.concat(@blocks)

  # Where each block starts in the concatenated wheel. Computed rather than
  # written down, so adding a character to a block cannot put the jumps out
  # of step with it.
  @starts @blocks
          |> Enum.scan(0, fn block, offset -> offset + length(block) end)
          |> then(&[0 | Enum.drop(&1, -1)])

  @typedoc "The editor: which network, the characters so far, and the caret."
  @type t :: %{
          ssid: String.t(),
          chars: [String.t()],
          caret: non_neg_integer()
        }

  @typedoc "What a press did."
  @type outcome :: {:editing, t()} | {:done, String.t()} | :cancelled

  @doc "A fresh editor for one network, empty, caret at the front."
  @spec new(String.t()) :: t()
  def new(ssid), do: %{ssid: ssid, chars: [], caret: 0}

  @doc "Everything picked so far."
  @spec value(t()) :: String.t()
  def value(%{chars: chars}), do: Enum.join(chars)

  @doc "How many characters have been picked."
  @spec length(t()) :: non_neg_integer()
  def length(%{chars: chars}), do: Kernel.length(chars)

  @doc """
  The character under the caret, or nil when the caret is past the end.

  Nil is the state the caret starts in and the state it returns to at the
  end of the string: there is a position there, and pressing up puts a
  character in it.
  """
  @spec current(t()) :: String.t() | nil
  def current(%{chars: chars, caret: caret}), do: Enum.at(chars, caret)

  @doc "The whole wheel, in the order the shoulder buttons jump through."
  @spec alphabet() :: [String.t()]
  def alphabet, do: @alphabet

  @doc """
  Hand the editor one semantic button, as `MayonnaiOS.Launcher` names them.

  Returns `{:done, passphrase}` on A -- whether or not the passphrase is long
  enough, because the length rule belongs to `MayonnaiOS.WiFi` and a picker
  that silently swallowed A would be a picker that looks broken. Everything
  it has no use for leaves it alone.
  """
  @spec input(t(), atom()) :: outcome()
  def input(editor, button)

  def input(editor, :left), do: {:editing, move(editor, -1)}
  def input(editor, :right), do: {:editing, move(editor, +1)}
  def input(editor, :up), do: {:editing, step(editor, -1)}
  def input(editor, :down), do: {:editing, step(editor, +1)}
  def input(editor, :l1), do: {:editing, jump(editor, -1)}
  def input(editor, :r1), do: {:editing, jump(editor, +1)}
  def input(editor, :y), do: {:editing, drop(editor)}
  def input(editor, :a), do: {:done, value(editor)}
  def input(_editor, :b), do: :cancelled
  def input(editor, _button), do: {:editing, editor}

  @doc """
  Move the caret, bounded rather than wrapping.

  Bounded because the two ends mean something here: the front is where a
  character was mistyped and the end is where the next one goes. A caret that
  wrapped from the end to the front would send someone who pressed right once
  too often back to the start of a passphrase they are in the middle of.
  """
  @spec move(t(), integer()) :: t()
  def move(%{chars: chars, caret: caret} = editor, delta) do
    %{editor | caret: caret |> Kernel.+(delta) |> max(0) |> min(Kernel.length(chars))}
  end

  @doc """
  Change the character under the caret, wrapping around the wheel.

  With the caret past the end this appends: the first press of a direction on
  an empty passphrase puts a character there and leaves the caret on it, so
  pressing up again steps that character rather than adding a second one.
  """
  @spec step(t(), integer()) :: t()
  def step(%{chars: chars, caret: caret} = editor, delta) do
    if caret >= Kernel.length(chars) do
      %{editor | chars: chars ++ [next(nil, delta)]}
    else
      current = Enum.at(chars, caret)
      %{editor | chars: List.replace_at(chars, caret, next(current, delta))}
    end
  end

  @doc """
  Jump the character under the caret to the head of the next or previous
  block.

  Past the end this appends the head of the first or last block, so the
  shoulder buttons start a passphrase as readily as a direction does.
  """
  @spec jump(t(), integer()) :: t()
  def jump(%{chars: chars, caret: caret} = editor, delta) do
    if caret >= Kernel.length(chars) do
      %{editor | chars: chars ++ [block_head(nil, delta)]}
    else
      current = Enum.at(chars, caret)
      %{editor | chars: List.replace_at(chars, caret, block_head(current, delta))}
    end
  end

  @doc """
  Remove the character under the caret.

  With the caret past the end it removes the last character, which is what
  the button means to someone who has just added one too many and has not
  moved.
  """
  @spec drop(t()) :: t()
  def drop(%{chars: []} = editor), do: editor

  def drop(%{chars: chars, caret: caret} = editor) do
    at = min(caret, Kernel.length(chars) - 1)
    chars = List.delete_at(chars, at)
    %{editor | chars: chars, caret: min(at, Kernel.length(chars))}
  end

  # A character the wheel does not know about has no position to step from,
  # so the first press replaces it with one end of the wheel rather than
  # doing nothing at all.
  defp next(current, delta) do
    case Enum.find_index(@alphabet, &(&1 == current)) do
      nil -> if delta < 0, do: List.last(@alphabet), else: hd(@alphabet)
      index -> Enum.at(@alphabet, Integer.mod(index + delta, Kernel.length(@alphabet)))
    end
  end

  # No character to jump from -- the caret is past the end, or on something
  # the wheel does not know -- so the two directions take the two ends: R1
  # starts at the first block, L1 at the last.
  defp block_head(current, delta) when is_nil(current) or delta == 0 do
    block_start(if delta < 0, do: Kernel.length(@starts) - 1, else: 0)
  end

  defp block_head(current, delta) do
    case block_of(current) do
      nil -> block_start(if delta < 0, do: Kernel.length(@starts) - 1, else: 0)
      block -> block_start(Integer.mod(block + delta, Kernel.length(@starts)))
    end
  end

  defp block_start(block), do: Enum.at(@alphabet, Enum.at(@starts, block))

  # Which block a character is in, or nil for one that is not on the wheel.
  defp block_of(current) do
    case Enum.find_index(@alphabet, &(&1 == current)) do
      nil -> nil
      index -> @starts |> Enum.take_while(&(&1 <= index)) |> Kernel.length() |> Kernel.-(1)
    end
  end
end
