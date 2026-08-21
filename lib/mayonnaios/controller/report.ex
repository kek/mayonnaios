defmodule MayonnaiOS.Controller.Report do
  @moduledoc """
  The gamepad as a host sees it: a HID report descriptor and the three bytes
  that go with it.

  This module is the whole of the "what kind of controller is this" question,
  and it is deliberately pure -- a report descriptor is a constant, and
  turning evdev presses into report bytes is a fold over a struct. Neither
  needs Bluetooth, so both are tested on a laptop and only the transport below
  them needs the handheld.

  ## The descriptor decides what the host believes

  A HID host does not probe a gamepad. It reads the report descriptor once, at
  connection time, and everything it will ever believe about the device comes
  from those bytes: how many buttons there are, how wide each report is, which
  bits mean what. Get the descriptor wrong and there is no error anywhere --
  the host parses it happily and reports the wrong buttons, or ignores the
  device entirely because it does not look like a gamepad.

  So the layout is written out explicitly below, byte by byte, with the item
  names next to the values. `descriptor/0` is assembled from those lines rather
  than pasted as a blob, because a blob is unreviewable and this is the one
  part of the stack where a silent mistake stays silent.

  ## What is declared

      Hat switch      the D-pad, 8 directions plus a null state
      Buttons 1..10   A B X Y L1 R1 L2 R2 Select Start

  A hat switch is what a D-pad is, and it is the only thing the D-pad is
  reported as.

  No axes are declared, and that is a statement about the kernel rather than
  about the hardware. This shell *does* have an analog stick -- unlike the
  RG35XX Plus whose device tree this board's was extended from -- but nothing
  in this firmware can see it: no `adc-joystick` driver, no joystick node, so
  no `ev_abs` on any input device. `InputEvent.enumerate/0` on the device
  shows `event0` offering fifteen keys and nothing else. Declaring axes that
  no input can ever move would put a dead stick in front of every host. The
  README's roadmap has what enabling it would take.

  ## The D-pad used to be declared twice, and that was the bug

  An earlier version of this descriptor also declared X and Y axes driven by
  the D-pad, on the reasoning that plenty of games only ever look at a stick
  and a controller with no axes at all would do nothing in them.

  What happened on a Mac, through Steam: the character moved correctly in four
  directions *and* the mouse pointer moved at the same time. One press, two
  consumers. Steam's own layer had taken the axes for a stick and bound that
  stick to the pointer -- with the two axes swapped, so up and down slid the
  cursor left and right -- while the game read the hat and did the right
  thing. In a menu, where nothing was reading the hat, all that was left was a
  wandering cursor.

  The reasoning was wrong in a way worth writing down, because it is
  tempting. Declaring one physical control twice does not give a host two
  chances to get it right; it gives two *different* pieces of software one
  each, and they do not agree. And the games the duplication was meant to
  rescue were never rescued by it: a game that reads a stick reads it through
  a mapping, and an unrecognised controller has no mapping whether or not it
  reports axes.

  ## Changing this descriptor means re-pairing

  A host reads the report map exactly once, when it pairs, and caches it
  against the device forever after. Editing anything in `descriptor/0` and
  reflashing therefore changes nothing at all on a host that has already
  paired: it goes on parsing new reports against the old layout, which is
  worse than no change, because the bytes have moved underneath it.

  Both ends have to forget each other. On the device that is
  `MayonnaiOS.Controller.unpair/0`; on the host it is removing the device in
  its Bluetooth settings.

  ## There is no report ID, and that is the point

  This device has exactly one input report, so it declares no Report ID item
  at all and `MayonnaiOS.Bluetooth.HOGP` puts 0 in the Report Reference
  descriptor, which is what 0 there means.

  An earlier version declared Report ID 1. Everything that read the report
  through a HID *parser* was fine with that -- a browser's gamepad API showed
  every button correctly -- while Steam listed the controller and received
  nothing from it at all. That split is the signature of a report ID: a
  parser asks the operating system for element values and never sees the ID,
  while software reading raw reports has to know whether the first byte is an
  ID or data, and the two conventions differ by exactly one byte.

  With no ID declared there is no convention to get wrong. Every consumer
  sees three bytes of report, and the first one is the hat.

  ## Report layout

      byte 0   bits 0-3 hat, bits 4-7 padding
      byte 1   buttons 1-8, one bit each, button 1 in bit 0
      byte 2   bits 0-1 buttons 9-10, bits 2-7 padding

  HID packs fields least-significant-bit first, in declaration order, which is
  why the hat lands in the low nibble and the padding item after it is not
  optional: without it the button field would start mid-byte and every button
  would be off by four bits.

  ## The button names are the ones on the plastic

  Linux's `BTN_A` is south and this board follows the Nintendo layout, so the
  atom `:btn_b` is the button silkscreened **A**; on top of that the device
  tree has X and Y the wrong way round, so `:btn_y` is the button
  silkscreened **X**. `MayonnaiOS.Launcher`'s moduledoc has the full account
  and the evidence. The table below is keyed by the atom that actually
  arrives and commented with the physical button, so it can be read without
  going and getting that account.

  Menu (`:btn_mode`) is deliberately absent. It is how you leave controller
  mode -- the same "Menu is the one way back" the launcher already has -- and
  a button that both exits and does something on the host would be a button
  you could not press safely.

  ## What is verified and what is not

  The kernel's own capability list settles most of it. `event0` declares
  exactly fifteen keys:

      btn_a btn_b btn_x btn_y btn_tl btn_tr btn_tl2 btn_tr2
      btn_select btn_start btn_mode
      btn_dpad_up btn_dpad_down btn_dpad_left btn_dpad_right

  Every one of them appears in the tables below or is deliberately left out,
  and nothing is declared that this module does not know about -- so there is
  no button on this shell that silently reaches a host as nothing.

  What that list cannot settle is which piece of plastic emits which code.
  A, B, X, Y and Select were checked by pressing them and watching, and two
  of those four turned out to contradict the device tree. The shoulders are
  not checked: `btn_tl2` is assumed to be L2 rather than, say, the pair being
  swapped the way X and Y were. The cost of that being wrong is a shoulder
  button in the wrong place rather than a crash, and
  `MayonnaiOS.Controller.Pad` logs any key that arrives without a mapping, so
  a correction is a log line away rather than a mystery.
  """

  @typedoc "Which way the D-pad is held."
  @type direction :: :up | :down | :left | :right

  @typedoc """
  Everything the host is told, before it is packed into bytes.

  `buttons` holds evdev atoms rather than button numbers so that the state is
  readable in a log line and in IEx; the numbering is applied at the last
  possible moment, in `encode/1`.
  """
  @type t :: %__MODULE__{
          buttons: MapSet.t(atom()),
          directions: MapSet.t(direction())
        }

  defstruct buttons: MapSet.new(), directions: MapSet.new()

  # evdev atom -> HID button number. The comment is the button as printed on
  # the shell; see the moduledoc for why those two disagree.
  @buttons %{
    # A
    btn_b: 1,
    # B
    btn_a: 2,
    # X
    btn_y: 3,
    # Y
    btn_x: 4,
    btn_tl: 5,
    btn_tr: 6,
    btn_tl2: 7,
    btn_tr2: 8,
    btn_select: 9,
    btn_start: 10
  }

  @button_count 10

  # evdev atom -> D-pad direction.
  @directions %{
    btn_dpad_up: :up,
    btn_dpad_down: :down,
    btn_dpad_left: :left,
    btn_dpad_right: :right
  }

  # Hat switch values, clockwise from north. 15 is out of the declared logical
  # range and so means "null" -- centred -- which is what the Null State flag
  # on the hat's Input item allows.
  @hat_null 15
  @hat %{
    [:up] => 0,
    [:right, :up] => 1,
    [:right] => 2,
    [:down, :right] => 3,
    [:down] => 4,
    [:down, :left] => 5,
    [:left] => 6,
    [:left, :up] => 7
  }

  @doc """
  The HID report descriptor, as bytes.

  This is what goes in the Report Map characteristic. It is assembled from the
  item list below so that a reviewer reads item names rather than hex.
  """
  @spec descriptor() :: binary()
  def descriptor do
    <<
      # Usage Page (Generic Desktop)
      0x05,
      0x01,
      # Usage (Game Pad)
      0x09,
      0x05,
      # Collection (Application)
      0xA1,
      0x01,
      # No Report ID item. See the moduledoc: this device has one report, and
      # declaring an ID for it only creates a question every host answers
      # differently.
      # Usage Page (Generic Desktop)
      0x05,
      0x01,
      # Usage (Hat Switch)
      0x09,
      0x39,
      # Logical Minimum (0)
      0x15,
      0x00,
      # Logical Maximum (7)
      0x25,
      0x07,
      # Physical Minimum (0)
      0x35,
      0x00,
      # Physical Maximum (315)
      0x46,
      0x3B,
      0x01,
      # Unit (Degrees, English rotation)
      0x65,
      0x14,
      # Report Size (4)
      0x75,
      0x04,
      # Report Count (1)
      0x95,
      0x01,
      # Input (Data, Variable, Absolute, Null State)
      0x81,
      0x42,
      # Unit (None) -- undo the degrees, or it applies to everything after
      0x65,
      0x00,
      # Report Size (4)
      0x75,
      0x04,
      # Report Count (1)
      0x95,
      0x01,
      # Input (Constant) -- pad the hat out to a whole byte
      0x81,
      0x03,
      # Usage Page (Button)
      0x05,
      0x09,
      # Usage Minimum (Button 1)
      0x19,
      0x01,
      # Usage Maximum (Button 10)
      0x29,
      @button_count,
      # Logical Minimum (0)
      0x15,
      0x00,
      # Logical Maximum (1)
      0x25,
      0x01,
      # Report Size (1)
      0x75,
      0x01,
      # Report Count (10)
      0x95,
      @button_count,
      # Input (Data, Variable, Absolute)
      0x81,
      0x02,
      # Report Size (1)
      0x75,
      0x01,
      # Report Count (6) -- pad the buttons out to two whole bytes
      0x95,
      0x06,
      # Input (Constant)
      0x81,
      0x03,
      # End Collection
      0xC0
    >>
  end

  @doc "How many bytes one input report takes. Five."
  @spec size() :: pos_integer()
  def size, do: byte_size(encode(%__MODULE__{}))

  @doc "Nothing pressed. What the host is sent when controller mode is left."
  @spec released() :: t()
  def released, do: %__MODULE__{}

  @doc """
  Fold one evdev report into the state.

  Takes the event list `InputEvent` delivers, so a whole report is applied at
  once -- the D-pad and a face button pressed in the same kernel report become
  one HID report rather than two, which is what the host expects and what
  keeps a diagonal from being two separate presses.

  evdev value 1 is a press, 0 a release, and 2 an auto-repeat. Repeats are
  applied as presses: they carry no new information here, but treating them as
  anything else would need a reason and there is not one.
  """
  @spec apply_events(t(), [tuple()]) :: t()
  def apply_events(state, events) when is_list(events) do
    Enum.reduce(events, state, &apply_event(&2, &1))
  end

  @doc """
  Fold a single evdev event in.

  Anything that is not a key this controller declares is returned unchanged --
  `EV_SYN`, the volume keys, an atom no table here knows. Unknown keys are not
  an error at this level; `MayonnaiOS.Controller` is the one that logs them,
  because it is the one that knows whether anybody is listening.
  """
  @spec apply_event(t(), tuple()) :: t()
  def apply_event(state, {:ev_key, key, value}) do
    cond do
      Map.has_key?(@buttons, key) ->
        %{state | buttons: toggle(state.buttons, key, value)}

      direction = Map.get(@directions, key) ->
        %{state | directions: toggle(state.directions, direction, value)}

      true ->
        state
    end
  end

  def apply_event(state, _event), do: state

  defp toggle(set, member, 0), do: MapSet.delete(set, member)
  defp toggle(set, member, _pressed), do: MapSet.put(set, member)

  @doc """
  Whether this atom means anything to the controller.

  Used by the caller to tell "a button with no mapping yet" from "a key that
  is not ours", so only the first gets logged.
  """
  @spec known?(atom()) :: boolean()
  def known?(key), do: Map.has_key?(@buttons, key) or Map.has_key?(@directions, key)

  @doc """
  Pack the state into the three bytes the descriptor promises.

      iex> alias MayonnaiOS.Controller.Report
      iex> Report.encode(Report.released())
      <<15, 0, 0>>
  """
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = state) do
    <<hat(state.directions)::8, buttons(state.buttons)::binary>>
  end

  @doc """
  The hat switch value for a set of directions, or 15 for centred.

  Opposite directions held together -- which the D-pad on this shell can
  physically do, since it is four separate switches under one cross -- cancel,
  giving centre. That is the same thing every other gamepad does, and the
  alternative is a lookup that fails and a report that never gets sent.
  """
  @spec hat(MapSet.t(direction())) :: 0..15
  def hat(directions) do
    Map.get(@hat, directions |> cancel() |> Enum.sort(), @hat_null)
  end

  # Up with down, or left with right, is not a direction. Drop both.
  defp cancel(directions) do
    Enum.reduce([[:up, :down], [:left, :right]], directions, fn pair, held ->
      if Enum.all?(pair, &MapSet.member?(held, &1)) do
        Enum.reduce(pair, held, &MapSet.delete(&2, &1))
      else
        held
      end
    end)
  end

  @doc "The two button bytes, button 1 in the low bit of the first."
  @spec buttons(MapSet.t(atom())) :: binary()
  def buttons(pressed) do
    bits =
      Enum.reduce(pressed, 0, fn key, acc ->
        case Map.fetch(@buttons, key) do
          {:ok, number} -> Bitwise.bor(acc, Bitwise.bsl(1, number - 1))
          :error -> acc
        end
      end)

    <<bits::16-little>>
  end

  @doc """
  The evdev atom -> HID button number table, for the diagnostics readout and
  for anyone wondering which button ended up where.
  """
  @spec button_map() :: %{atom() => pos_integer()}
  def button_map, do: @buttons

  @doc "The evdev atom -> D-pad direction table."
  @spec direction_map() :: %{atom() => direction()}
  def direction_map, do: @directions
end
