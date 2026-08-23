defmodule MayonnaiOS.Pickles.Frame do
  @moduledoc """
  The `ui` capability's data: what a pickle may draw, and what a button is
  called.

  A graphical pickle does not own a scene process or a graph -- it owns a
  function. `on_draw()` returns a *display list*, an array of plain tables:

      function on_draw()
        return {
          {kind = "rect", x = 0, y = 0, w = 640, h = 480, color = "black"},
          {kind = "text", x = 40, y = 60, text = "hello", size = 32},
          {kind = "line", x1 = 0, y1 = 80, x2 = 640, y2 = 80, color = "gray"},
          {kind = "circle", x = 320, y = 240, r = 24, color = "red", fill = false},
        }
      end

  This module turns that -- already decoded into Elixir terms -- into
  validated draw ops for `MayonnaiOS.Scene.Pickle`, which applies them to a
  Scenic graph. The validation is the sandbox's edge: coordinates become
  integers, colors come from a fixed palette, text length is capped, and the
  op count is capped, so a script cannot hand the UI process anything the
  renderer was not written for.

  Invalid entries are counted rather than silently dropped -- the scene
  prints the count -- and rather than raising, because one malformed table in
  a list of forty should cost one missing shape and a visible tally, not the
  whole frame. Same philosophy as `Programs` rendering broken entries.

  ## Button names

  Scripts see the names printed on the plastic: `a b x y up down left right
  l1 r1 l2 r2 select start`. The evdev atoms underneath disagree with the
  silkscreen twice over (Linux's Xbox-layout naming, plus a device tree with
  X and Y swapped -- `MayonnaiOS.Launcher`'s moduledoc has the account), and
  no pickle author should need to know that. Menu is absent on purpose: it is
  how the player leaves, and the launcher never hands it over.
  """

  @max_ops 256
  @max_text 200

  # The plastic name for each evdev atom. See the moduledoc; the pairs that
  # look wrong are the ones that are right.
  @buttons %{
    btn_b: "a",
    btn_a: "b",
    btn_y: "x",
    btn_x: "y",
    btn_tl: "l1",
    btn_tr: "r1",
    btn_tl2: "l2",
    btn_tr2: "r2",
    btn_select: "select",
    btn_start: "start",
    btn_dpad_up: "up",
    btn_dpad_down: "down",
    btn_dpad_left: "left",
    btn_dpad_right: "right"
  }

  # A fixed palette rather than arbitrary RGB, at least for now: every name
  # here is a Scenic named color, so validation is membership and the scene
  # can pass the atom straight through.
  @colors %{
    "white" => :white,
    "black" => :black,
    "red" => :red,
    "green" => :green,
    "blue" => :blue,
    "yellow" => :yellow,
    "orange" => :orange,
    "purple" => :purple,
    "cyan" => :cyan,
    "magenta" => :magenta,
    "gray" => :gray,
    "grey" => :gray,
    "dark_gray" => :dark_gray,
    "light_gray" => :light_gray,
    "brown" => :brown,
    "pink" => :pink,
    "lime" => :lime,
    "navy" => :navy,
    "teal" => :teal,
    "gold" => :gold
  }

  @panel {640, 480}

  @type op ::
          {:text,
           %{x: integer(), y: integer(), text: String.t(), size: pos_integer(), color: atom()}}
          | {:rect,
             %{
               x: integer(),
               y: integer(),
               w: integer(),
               h: integer(),
               color: atom(),
               fill: boolean()
             }}
          | {:line,
             %{
               x1: integer(),
               y1: integer(),
               x2: integer(),
               y2: integer(),
               color: atom(),
               width: pos_integer()
             }}
          | {:circle, %{x: integer(), y: integer(), r: integer(), color: atom(), fill: boolean()}}

  @doc "The panel, in pixels. What `mayo.ui.size()` answers."
  def panel_size, do: @panel

  @doc """
  The plastic name for an evdev key atom, or `nil` for keys pickles do not
  get (Menu, the power button, anything unexpected).
  """
  @spec button_name(atom()) :: String.t() | nil
  def button_name(key), do: @buttons[key]

  @doc """
  A display list as it came out of Lua, turned into validated ops.

  Returns `%{ops: [op], invalid: count}`. Anything that is not a list is a
  frame of zero ops with one invalid entry -- a script that returned a
  string still gets a frame, and the frame says what is wrong with it.
  """
  @spec build(term()) :: %{ops: [op()], invalid: non_neg_integer()}
  def build(entries) when is_list(entries) do
    {ops, invalid} =
      entries
      |> Enum.take(@max_ops)
      |> Enum.reduce({[], 0}, fn entry, {ops, invalid} ->
        case op(entry) do
          {:ok, op} -> {[op | ops], invalid}
          :error -> {ops, invalid + 1}
        end
      end)

    over = max(length(entries) - @max_ops, 0)
    %{ops: Enum.reverse(ops), invalid: invalid + over}
  end

  def build(_other), do: %{ops: [], invalid: 1}

  # -- ops ---------------------------------------------------------------------

  defp op(%{"kind" => "text"} = e) do
    with {:ok, x} <- int(e["x"]),
         {:ok, y} <- int(e["y"]),
         text when is_binary(text) <- e["text"] do
      {:ok,
       {:text,
        %{
          x: x,
          y: y,
          text: String.slice(text, 0, @max_text),
          size: size(e["size"], 16),
          color: color(e["color"])
        }}}
    else
      _ -> :error
    end
  end

  defp op(%{"kind" => "rect"} = e) do
    with {:ok, x} <- int(e["x"]),
         {:ok, y} <- int(e["y"]),
         {:ok, w} <- int(e["w"]),
         {:ok, h} <- int(e["h"]) do
      {:ok, {:rect, %{x: x, y: y, w: w, h: h, color: color(e["color"]), fill: fill(e)}}}
    else
      _ -> :error
    end
  end

  defp op(%{"kind" => "line"} = e) do
    with {:ok, x1} <- int(e["x1"]),
         {:ok, y1} <- int(e["y1"]),
         {:ok, x2} <- int(e["x2"]),
         {:ok, y2} <- int(e["y2"]) do
      {:ok,
       {:line,
        %{x1: x1, y1: y1, x2: x2, y2: y2, color: color(e["color"]), width: size(e["width"], 1)}}}
    else
      _ -> :error
    end
  end

  defp op(%{"kind" => "circle"} = e) do
    with {:ok, x} <- int(e["x"]),
         {:ok, y} <- int(e["y"]),
         {:ok, r} <- int(e["r"]) do
      {:ok, {:circle, %{x: x, y: y, r: r, color: color(e["color"]), fill: fill(e)}}}
    else
      _ -> :error
    end
  end

  defp op(_other), do: :error

  defp int(n) when is_integer(n), do: {:ok, n}
  defp int(n) when is_float(n), do: {:ok, trunc(n)}
  defp int(_), do: :error

  # Sizes and widths are clamped rather than rejected: an off-by-a-lot font
  # size should look wrong on the panel, not vanish into the invalid count.
  defp size(n, _default) when is_number(n), do: n |> trunc() |> max(1) |> min(200)
  defp size(_, default), do: default

  defp color(name), do: Map.get(@colors, name, :white)

  defp fill(%{"fill" => false}), do: false
  defp fill(_), do: true
end
