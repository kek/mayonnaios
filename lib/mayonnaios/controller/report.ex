defmodule MayonnaiOS.Controller.Report do
  @moduledoc """
  The gamepad as a host sees it: the Xbox Wireless Controller's HID report
  descriptor, byte for byte, and the sixteen bytes that go with it.

  This module is the whole of the "what kind of controller is this" question,
  and it is deliberately pure -- a report descriptor is a constant, and
  turning evdev events into report bytes is a fold over a struct. Neither
  needs Bluetooth, so both are tested on a laptop and only the transport below
  them needs the handheld.

  ## The identity is borrowed, and that is the point

  An honest descriptor -- a hat and ten buttons under pid.codes numbers --
  cannot practically drive a game: SDL matches gamepads against a database
  keyed by vendor and product numbers, an unlisted device is a joystick
  rather than a game controller, and on macOS Steam Input has no virtual
  controller to bridge the gap with. Everything downstream of an honest
  identity is a workaround for the device saying who it really is.

  So it does not say that. The descriptor below is the Xbox Wireless
  Controller's -- model 1914, the BLE firmware, product 0x0B13 -- reproduced
  exactly, and `MayonnaiOS.Bluetooth.HOGP` claims the matching vendor and
  product numbers. Hosts with first-class Xbox support (macOS through the
  GameController framework and SDL's HIDAPI driver, the Steam Deck, Windows,
  phones) recognise it with no mapping step, which is the whole ask.

  The objection to a borrowed identity is that a host with a *driver* for
  the claimed controller stops reading the descriptor and parses reports
  against the real device's fixed layout, so any deviation is scrambled
  buttons the host is certain are correct. That objection is to guessing
  someone else's layout while shipping your own, and it dissolves when the
  layout *is* theirs: the fixed format the drivers assume is exactly what
  these bytes declare and exactly what `encode/1` packs. The driver
  mechanism is the payoff rather than the risk.

  ## Byte-exact or nothing

  The descriptor is transcribed from the capture that ships in
  ESP32-BLE-CompositeHID (`XboxOneS_1914_HIDDescriptor`, taken from a real
  pad with the BLE firmware), and the test suite pins all 283 bytes against
  that reference. This is the one place where a helpful-looking improvement
  is a bug: reordering an item, dropping the vestigial rumble collection,
  "fixing" the 0..65535 axes to be signed -- any of it produces a device the
  drivers misparse while the descriptor reads fine. Edit this only to track
  the real controller, and re-pin the test from a fresh capture when you do.

  ## What is real and what is at rest

  The 1914 declares more controls than this shell has. What is missing is
  reported permanently at rest, which is indistinguishable from a player not
  touching it:

      left stick    real -- the ADC stick, scaled from 0..4096 to 0..65535
      right stick   absent; reported centred (0x8000, 0x8000) forever
      triggers      the shell's L2/R2 are switches, so 0 or fully pulled
      LS, RS        no stick clicks on this shell; never pressed
      Xbox button   not reported; Menu on the shell is the way out of the app
      Share button  not reported

  The rumble output report the descriptor declares is accepted by the GATT
  server and dropped -- there is no motor. A host that rumbles hears silence,
  which is what a pad with a dead motor sounds like, and nothing retries.

  ## The report ID

  Report IDs are a compatibility hazard: software reading *raw* reports has
  to know whether the first byte is an ID or data, and for an unknown device
  the two conventions split hosts into camps -- Steam can list a controller
  and receive nothing from it.

  The Xbox descriptor declares ID 1 because the real pad does, and the reports
  this module encodes still carry no ID byte -- over HID-over-GATT the ID
  travels in the Report Reference descriptor next to the characteristic, not
  in the notification. That is the same framing the real controller uses, so
  the code paths parsing it are the ones every Xbox pad on Bluetooth already
  exercises. That failure is the cost of being nobody; it does not carry
  over to being somebody the host knows.

  ## Report layout

  Sixteen bytes, fields little-endian, packed LSB first in declaration order:

      bytes 0-1    left stick X, 0..65535
      bytes 2-3    left stick Y, 0..65535
      bytes 4-5    right stick X, always 0x8000
      bytes 6-7    right stick Y, always 0x8000
      bytes 8-9    brake (left trigger), 10 bits, 0..1023
      bytes 10-11  accelerator (right trigger), 10 bits, 0..1023
      byte 12      bits 0-3 hat: 0 centred, 1 north, clockwise to 8 north-west
      bytes 13-14  fifteen buttons, one bit each, A in bit 0
      byte 15      bit 0 Share, which this shell does not have

  ## The button names are the ones on the plastic

  Linux's `BTN_A` is south and this board follows the Nintendo layout, so the
  atom `:btn_b` is the button silkscreened **A**; on top of that the device
  tree has X and Y the wrong way round, so `:btn_y` is the button
  silkscreened **X**. `MayonnaiOS.Launcher`'s moduledoc has the full account
  and the evidence.

  Mapping is label to label: the button printed A on the shell is the Xbox A,
  wherever each sits. A game saying "press A" means the glyph, the player
  reads the plastic, and label-to-label is the only mapping where those two
  agree without a diagram. The Xbox layout puts A south where this shell
  prints it east; anyone who finds that positional swap unplayable can remap
  it on the host, which -- with the pad recognised -- is a supported
  operation rather than a workaround.

  Menu (`:btn_mode`) is deliberately absent. It is how you leave controller
  mode -- the same "Menu is the one way back" the launcher already has -- and
  a button that both exits and does something on the host would be a button
  you could not press safely. For the same reason it is *not* mapped to the
  Xbox button, which on every host summons an overlay.

  ## Select+Start held together is the Xbox button

  The shell has no plastic for the Xbox button, and on a Steam Deck that
  button is how you reach Steam. So the chord: while Select and Start are
  both down, the report says Xbox and says neither View nor Menu.

  The edges are where chords go wrong, and both are decided here. On the way
  in, whichever half goes down first is reported alone for the beat before
  the other arrives -- a brief View or Menu press the host really sees.
  Swallowing it would take a timer holding every Select and Start hostage
  against a chord that usually is not coming, and this fold owns no clock;
  a game that pauses on Menu may pause on the way into the overlay, which is
  where the player was headed anyway. On the way out the same leak would be
  worse -- release one half and the other would read as a fresh press,
  re-opening the pause menu the overlay was closed onto -- so the chord
  *latches*: once it fires, View and Menu stay suppressed until both halves
  are up. In, Xbox; out, silence; the two single buttons work exactly as
  before when the chord is never completed.

  ## The stick arrives in twelfths and leaves in two-fifty-sixths

  `adc-joystick` delivers 0..4096 and the report promises 0..65535, so values
  are scaled up and then quantised to 256 steps. The quantisation is not
  laziness: the low bits of a 12-bit ADC are noise, every twitch of them
  would be a report the radio has to carry (`MayonnaiOS.Controller.Pad` sends
  on change), and 256 positions per axis is more than a thumb on a 30 mm
  stick can express anyway. The Y axis is flipped on the way through --
  this ADC's Y grows toward physically up where HID's grows toward down --
  and that is a fact read off a Steam Deck with the stick in hand, not an
  assumption; the first firmware to carry the stick shipped it straight and
  walked everything upside down.

  ## Changing this descriptor means re-pairing

  A host reads the report map exactly once, when it pairs, and caches it
  against the device forever after. Editing anything in `descriptor/0` and
  reflashing therefore changes nothing at all on a host that has already
  paired: it goes on parsing new reports against the layout it cached, which
  is worse than no change, because the bytes have moved underneath it. The
  host must forget the device **and** `MayonnaiOS.Controller.unpair/0` must
  run here, or the host parses the new reports against the cached layout and
  reports garbage with total confidence.
  """

  @typedoc "Which way the D-pad is held."
  @type direction :: :up | :down | :left | :right

  @typedoc """
  Everything the host is told, before it is packed into bytes.

  `buttons` holds evdev atoms rather than bit masks so that the state is
  readable in a log line and in IEx; the packing is applied at the last
  possible moment, in `encode/1`. The axes and triggers are stored already
  scaled, because the report's units are the only units anything downstream
  speaks.
  """
  @type t :: %__MODULE__{
          buttons: MapSet.t(atom()),
          directions: MapSet.t(direction()),
          chorded: boolean(),
          x: 0..0xFFFF,
          y: 0..0xFFFF,
          brake: 0..0x3FF,
          accelerator: 0..0x3FF
        }

  # A stick at rest is the middle of an unsigned range, not zero. Zero is a
  # stick pinned to one corner, which is what the right-stick fields would
  # have said forever had they defaulted like the triggers do.
  @centre 0x8000

  defstruct buttons: MapSet.new(),
            directions: MapSet.new(),
            chorded: false,
            x: @centre,
            y: @centre,
            brake: 0,
            accelerator: 0

  # evdev atom -> the button's bit in the fifteen-bit field, numbered the way
  # the 1914 numbers them (button 1 in bit 0; bits 2, 5, 8 and 9 belong to
  # controls this shell does not have). The comment is the label on the
  # plastic; see the moduledoc for why the atoms disagree with it.
  @buttons %{
    # A
    btn_b: 0x0001,
    # B
    btn_a: 0x0002,
    # X
    btn_y: 0x0008,
    # Y
    btn_x: 0x0010,
    # L1, the Xbox LB
    btn_tl: 0x0040,
    # R1, the Xbox RB
    btn_tr: 0x0080,
    # Select, the Xbox View button -- and half of the Xbox-button chord
    btn_select: 0x0400,
    # Start, the Xbox Menu button -- the other half
    btn_start: 0x0800
  }

  # The Xbox button, which this shell reaches through Select+Start held
  # together, and the two bits the chord suppresses while it does. See the
  # moduledoc.
  @guide 0x1000
  @view_and_menu 0x0C00
  @chord [:btn_select, :btn_start]

  # evdev atom -> the trigger field it fills. The shell's L2 and R2 are
  # switches, so a press is a fully pulled trigger and a release is a
  # released one; the ten-bit range exists for pads whose triggers travel.
  @trigger_full 0x3FF
  @triggers %{btn_tl2: :brake, btn_tr2: :accelerator}

  # evdev atom -> D-pad direction.
  @directions %{
    btn_dpad_up: :up,
    btn_dpad_down: :down,
    btn_dpad_left: :left,
    btn_dpad_right: :right
  }

  # The ADC's range. Only the left stick exists; abs events for anything
  # else fall through `apply_event/2` untouched.
  @axis_in_max 4096

  # Hat switch values, clockwise from north. The 1914 numbers directions from
  # 1 and uses 0 -- below the declared logical minimum -- as the null state.
  # The constants are the host's to dictate.
  @hat_null 0
  @hat %{
    [:up] => 1,
    [:right, :up] => 2,
    [:right] => 3,
    [:down, :right] => 4,
    [:down] => 5,
    [:down, :left] => 6,
    [:left] => 7,
    [:left, :up] => 8
  }

  # -- The descriptor, in the 1914's own order ------------------------------
  #
  # Transcribed item by item rather than pasted as a blob so that a reviewer
  # reads names against bytes; the test suite holds the assembled whole
  # against the reference capture, so a typo here is a failing test rather
  # than a host silently misparsing.

  # Usage Page (Generic Desktop), Usage (Game Pad), Collection (Application),
  # Report ID (1).
  @open <<0x05, 0x01, 0x09, 0x05, 0xA1, 0x01, 0x85, 0x01>>

  # The left stick: a Pointer physical collection holding X and Y, sixteen
  # unsigned bits each. The four-byte logical maximum (0x27) is how the
  # real pad spells 65535, so it is how this one does.
  @left_stick <<
    # Usage (Pointer), Collection (Physical)
    0x09,
    0x01,
    0xA1,
    0x00,
    # Usage (X), Usage (Y)
    0x09,
    0x30,
    0x09,
    0x31,
    # Logical Minimum (0), Logical Maximum (65535)
    0x15,
    0x00,
    0x27,
    0xFF,
    0xFF,
    0x00,
    0x00,
    # Report Count (2), Report Size (16), Input (Data, Variable, Absolute)
    0x95,
    0x02,
    0x75,
    0x10,
    0x81,
    0x02,
    # End Collection
    0xC0
  >>

  # The right stick this shell does not have: Z and Rz, same shape. Declared
  # because the 1914 declares it; fed the centre forever.
  @right_stick <<
    # Usage (Pointer), Collection (Physical)
    0x09,
    0x01,
    0xA1,
    0x00,
    # Usage (Z), Usage (Rz)
    0x09,
    0x32,
    0x09,
    0x35,
    # Logical Minimum (0), Logical Maximum (65535)
    0x15,
    0x00,
    0x27,
    0xFF,
    0xFF,
    0x00,
    0x00,
    # Report Count (2), Report Size (16), Input (Data, Variable, Absolute)
    0x95,
    0x02,
    0x75,
    0x10,
    0x81,
    0x02,
    # End Collection
    0xC0
  >>

  # Left trigger: Simulation Controls page, Usage (Brake), ten bits in a
  # sixteen-bit field. The six padding bits reset the logical maximum first,
  # because global items are sticky.
  @brake <<
    # Usage Page (Simulation Controls), Usage (Brake)
    0x05,
    0x02,
    0x09,
    0xC5,
    # Logical Minimum (0), Logical Maximum (1023)
    0x15,
    0x00,
    0x26,
    0xFF,
    0x03,
    # Report Count (1), Report Size (10), Input (Data, Variable, Absolute)
    0x95,
    0x01,
    0x75,
    0x0A,
    0x81,
    0x02,
    # Logical Minimum (0), Logical Maximum (0)
    0x15,
    0x00,
    0x25,
    0x00,
    # Report Size (6), Report Count (1), Input (Constant)
    0x75,
    0x06,
    0x95,
    0x01,
    0x81,
    0x03
  >>

  # Right trigger: Usage (Accelerator), otherwise identical.
  @accelerator <<
    # Usage Page (Simulation Controls), Usage (Accelerator)
    0x05,
    0x02,
    0x09,
    0xC4,
    # Logical Minimum (0), Logical Maximum (1023)
    0x15,
    0x00,
    0x26,
    0xFF,
    0x03,
    # Report Count (1), Report Size (10), Input (Data, Variable, Absolute)
    0x95,
    0x01,
    0x75,
    0x0A,
    0x81,
    0x02,
    # Logical Minimum (0), Logical Maximum (0)
    0x15,
    0x00,
    0x25,
    0x00,
    # Report Size (6), Report Count (1), Input (Constant)
    0x75,
    0x06,
    0x95,
    0x01,
    0x81,
    0x03
  >>

  # The D-pad, as a hat switch: 1..8 clockwise from north, 0 for centred via
  # the Null State flag. The padding afterwards zeroes every global item the
  # hat set -- units included, or the buttons would be reported in degrees.
  @hat_switch <<
    # Usage Page (Generic Desktop), Usage (Hat Switch)
    0x05,
    0x01,
    0x09,
    0x39,
    # Logical Minimum (1), Logical Maximum (8)
    0x15,
    0x01,
    0x25,
    0x08,
    # Physical Minimum (0), Physical Maximum (315)
    0x35,
    0x00,
    0x46,
    0x3B,
    0x01,
    # Unit (Degrees, English rotation)
    0x66,
    0x14,
    0x00,
    # Report Size (4), Report Count (1), Input (Data, Variable, Absolute, Null State)
    0x75,
    0x04,
    0x95,
    0x01,
    0x81,
    0x42,
    # Report Size (4), Report Count (1)
    0x75,
    0x04,
    0x95,
    0x01,
    # Logical Minimum (0), Logical Maximum (0)
    0x15,
    0x00,
    0x25,
    0x00,
    # Physical Minimum (0), Physical Maximum (0), Unit (None)
    0x35,
    0x00,
    0x45,
    0x00,
    0x65,
    0x00,
    # Input (Constant)
    0x81,
    0x03
  >>

  # Fifteen buttons and a padding bit. Which bit is which button is the
  # driver's fixed belief; the @buttons table above is its mirror.
  @fifteen_buttons <<
    # Usage Page (Button), Usage Minimum (1), Usage Maximum (15)
    0x05,
    0x09,
    0x19,
    0x01,
    0x29,
    0x0F,
    # Logical Minimum (0), Logical Maximum (1)
    0x15,
    0x00,
    0x25,
    0x01,
    # Report Size (1), Report Count (15), Input (Data, Variable, Absolute)
    0x75,
    0x01,
    0x95,
    0x0F,
    0x81,
    0x02,
    # Logical Minimum (0), Logical Maximum (0)
    0x15,
    0x00,
    0x25,
    0x00,
    # Report Size (1), Report Count (1), Input (Constant)
    0x75,
    0x01,
    0x95,
    0x01,
    0x81,
    0x03
  >>

  # The Share button, on the Consumer page as Usage (Record). Not a button
  # this shell has; the byte it lives in is sent as zero.
  @share <<
    # Usage Page (Consumer), Usage (Record)
    0x05,
    0x0C,
    0x0A,
    0xB2,
    0x00,
    # Logical Minimum (0), Logical Maximum (1)
    0x15,
    0x00,
    0x25,
    0x01,
    # Report Count (1), Report Size (1), Input (Data, Variable, Absolute)
    0x95,
    0x01,
    0x75,
    0x01,
    0x81,
    0x02,
    # Logical Minimum (0), Logical Maximum (0)
    0x15,
    0x00,
    0x25,
    0x00,
    # Report Size (7), Report Count (1), Input (Constant)
    0x75,
    0x07,
    0x95,
    0x01,
    0x81,
    0x03
  >>

  # The rumble output report, ID 3: Physical Interface Device page, a Set
  # Effect Report collection -- actuator enable bits, four magnitudes,
  # duration, start delay, loop count. Eight bytes a host may write and this
  # device reads never; declared because a driver that knows the 1914 knows
  # it has motors, and a missing report is a difference where none is
  # affordable.
  @rumble <<
    # Usage Page (Physical Interface Device), Usage (Set Effect Report)
    0x05,
    0x0F,
    0x09,
    0x21,
    # Report ID (3), Collection (Logical)
    0x85,
    0x03,
    0xA1,
    0x02,
    # Usage (DC Enable Actuators)
    0x09,
    0x97,
    # Logical Minimum (0), Logical Maximum (1)
    0x15,
    0x00,
    0x25,
    0x01,
    # Report Size (4), Report Count (1), Output (Data, Variable, Absolute)
    0x75,
    0x04,
    0x95,
    0x01,
    0x91,
    0x02,
    # Logical Minimum (0), Logical Maximum (0)
    0x15,
    0x00,
    0x25,
    0x00,
    # Report Size (4), Report Count (1), Output (Constant)
    0x75,
    0x04,
    0x95,
    0x01,
    0x91,
    0x03,
    # Usage (Magnitude)
    0x09,
    0x70,
    # Logical Minimum (0), Logical Maximum (100)
    0x15,
    0x00,
    0x25,
    0x64,
    # Report Size (8), Report Count (4), Output (Data, Variable, Absolute)
    0x75,
    0x08,
    0x95,
    0x04,
    0x91,
    0x02,
    # Usage (Duration), Unit (Seconds), Unit Exponent (-2)
    0x09,
    0x50,
    0x66,
    0x01,
    0x10,
    0x55,
    0x0E,
    # Logical Minimum (0), Logical Maximum (255)
    0x15,
    0x00,
    0x26,
    0xFF,
    0x00,
    # Report Size (8), Report Count (1), Output (Data, Variable, Absolute)
    0x75,
    0x08,
    0x95,
    0x01,
    0x91,
    0x02,
    # Usage (Start Delay)
    0x09,
    0xA7,
    # Logical Minimum (0), Logical Maximum (255)
    0x15,
    0x00,
    0x26,
    0xFF,
    0x00,
    # Report Size (8), Report Count (1), Output (Data, Variable, Absolute)
    0x75,
    0x08,
    0x95,
    0x01,
    0x91,
    0x02,
    # Unit (None), Unit Exponent (0)
    0x65,
    0x00,
    0x55,
    0x00,
    # Usage (Loop Count)
    0x09,
    0x7C,
    # Logical Minimum (0), Logical Maximum (255)
    0x15,
    0x00,
    0x26,
    0xFF,
    0x00,
    # Report Size (8), Report Count (1), Output (Data, Variable, Absolute)
    0x75,
    0x08,
    0x95,
    0x01,
    0x91,
    0x02,
    # End Collection
    0xC0
  >>

  # End Collection, closing the Game Pad application collection.
  @close <<0xC0>>

  @descriptor @open <>
                @left_stick <>
                @right_stick <>
                @brake <>
                @accelerator <>
                @hat_switch <> @fifteen_buttons <> @share <> @rumble <> @close

  @doc """
  The HID report descriptor, as bytes: the Xbox Wireless Controller 1914's,
  all 283 of them.

  This is what goes in the Report Map characteristic, and byte-exactness is
  the contract -- see the moduledoc.
  """
  @spec descriptor() :: binary()
  def descriptor, do: @descriptor

  @doc "How many bytes one input report takes. Sixteen."
  @spec size() :: pos_integer()
  def size, do: byte_size(encode(%__MODULE__{}))

  @doc "Nothing pressed, sticks centred. What the host is sent when controller mode is left."
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

  Anything that is not a control this report carries is returned unchanged --
  `EV_SYN`, the volume keys, an atom no table here knows. Unknown keys are not
  an error at this level; `MayonnaiOS.Controller` is the one that logs them,
  because it is the one that knows whether anybody is listening.
  """
  @spec apply_event(t(), tuple()) :: t()
  def apply_event(state, {:ev_key, key, value}) do
    cond do
      Map.has_key?(@buttons, key) ->
        update_chord(%{state | buttons: toggle(state.buttons, key, value)})

      field = Map.get(@triggers, key) ->
        Map.put(state, field, if(value == 0, do: 0, else: @trigger_full))

      direction = Map.get(@directions, key) ->
        %{state | directions: toggle(state.directions, direction, value)}

      true ->
        state
    end
  end

  def apply_event(state, {:ev_abs, :abs_x, value}), do: %{state | x: scale(value)}

  # Flipped, and checked on the hardware rather than assumed: this ADC's Y
  # grows toward physically up, HID's Y grows toward down, and shipping the
  # value straight through moved the world upside down on a Steam Deck.
  def apply_event(state, {:ev_abs, :abs_y, value}), do: %{state | y: scale(@axis_in_max - value)}

  def apply_event(state, _event), do: state

  defp toggle(set, member, 0), do: MapSet.delete(set, member)
  defp toggle(set, member, _pressed), do: MapSet.put(set, member)

  # The chord latches when both halves are down and lets go only when both
  # are up. The latch is what keeps a staggered release honest: without it,
  # lifting Select a beat before Start would re-press Menu on the way out of
  # the overlay the chord just opened.
  defp update_chord(state) do
    cond do
      Enum.all?(@chord, &MapSet.member?(state.buttons, &1)) -> %{state | chorded: true}
      not Enum.any?(@chord, &MapSet.member?(state.buttons, &1)) -> %{state | chorded: false}
      true -> state
    end
  end

  # 0..4096 in, 0..65535 out, quantised to steps of 256. The multiplier is 16
  # rather than 65535/4096 so that the ADC's centre, 2048, lands exactly on
  # 0x8000 -- and the quantisation rounds to the *nearest* step, which parks
  # the step boundaries a half-step away from any resting value instead of
  # exactly on the centre, where the noise would sit astride one. The clamps
  # are because evdev promises a range, not that every driver honours it.
  defp scale(value) do
    scaled = (value |> max(0) |> min(@axis_in_max)) * 16
    min(div(scaled + 128, 256) * 256, 0xFFFF)
  end

  @doc """
  Whether this key atom means anything to the controller.

  Used by the caller to tell "a button with no mapping yet" from "a key that
  is not ours", so only the first gets logged.
  """
  @spec known?(atom()) :: boolean()
  def known?(key) do
    Map.has_key?(@buttons, key) or Map.has_key?(@triggers, key) or
      Map.has_key?(@directions, key)
  end

  @doc """
  Pack the state into the sixteen bytes the descriptor promises.

      iex> alias MayonnaiOS.Controller.Report
      iex> Report.encode(Report.released())
      <<0, 0x80, 0, 0x80, 0, 0x80, 0, 0x80, 0, 0, 0, 0, 0, 0, 0, 0>>

  The right stick is the constant centre, and the Share byte is a constant
  zero; both belong to controls this shell does not have.
  """
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = state) do
    <<
      state.x::16-little,
      state.y::16-little,
      @centre::16-little,
      @centre::16-little,
      state.brake::16-little,
      state.accelerator::16-little,
      hat(state.directions)::8,
      buttons(state)::binary,
      0::8
    >>
  end

  @doc """
  The hat switch value for a set of directions, or 0 for centred.

  Opposite directions held together -- which the D-pad on this shell can
  physically do, since it is four separate switches under one cross -- cancel,
  giving centre. That is the same thing every other gamepad does, and the
  alternative is a lookup that fails and a report that never gets sent.
  """
  @spec hat(MapSet.t(direction())) :: 0..8
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

  # The two button bytes, the Xbox A in the low bit of the first. The chord
  # rewrites what the table says: both halves down is the Xbox button and
  # neither View nor Menu, and while the latch holds, whichever half is
  # still down on the way out stays silent too.
  defp buttons(%__MODULE__{} = state) do
    bits =
      Enum.reduce(state.buttons, 0, fn key, acc ->
        Bitwise.bor(acc, Map.get(@buttons, key, 0))
      end)

    bits =
      cond do
        Enum.all?(@chord, &MapSet.member?(state.buttons, &1)) ->
          bits |> Bitwise.band(Bitwise.bnot(@view_and_menu)) |> Bitwise.bor(@guide)

        state.chorded ->
          Bitwise.band(bits, Bitwise.bnot(@view_and_menu))

        true ->
          bits
      end

    <<bits::16-little>>
  end

  @doc """
  The evdev atom -> button bit mask table, for the diagnostics readout and
  for anyone wondering which button ended up where.
  """
  @spec button_map() :: %{atom() => pos_integer()}
  def button_map, do: @buttons

  @doc "The evdev atom -> trigger field table."
  @spec trigger_map() :: %{atom() => :brake | :accelerator}
  def trigger_map, do: @triggers

  @doc "The evdev atom -> D-pad direction table."
  @spec direction_map() :: %{atom() => direction()}
  def direction_map, do: @directions
end
