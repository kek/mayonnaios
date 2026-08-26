defmodule MayonnaiOS.Input do
  @moduledoc """
  Finding an input device by what it is, and saying so when it is not there.

  `/dev/input/eventN` is assigned in probe order, and probe order is not a
  promise: adding one device to the board is enough to renumber the others,
  and the BSP's `adc-joystick` node and `CONFIG_INPUT_AXP20X_PEK`'s power key
  have each done it once. Read off the device on firmware `3cc86f59`:

      event0  axp20x-pek                       the power button
      event1  adc-joystick                     the analog stick, read by nothing
      event2  gpio-keys-gamepad                the buttons and the D-pad
      event3  gpio-keys-volume                 the volume rocker
      event4  H616 Audio Codec Headphone Jack  the jack switch

  That table is here to be read, not to be depended on: what callers ask for
  is the name, which comes from the device tree and changes only when
  somebody changes it on purpose.

  ## There is no fallback, and that is the point

  A numbered path to fall back on when the name is not found reads as
  strictly safer than a bare `nil`. It is not.

  A fallback only ever runs in the state where the name is absent, and a
  number reached in that state does not name a worse version of the right
  device. It names a different device. `event1` is the analog stick: opening it
  and waiting for `KEY_VOLUMEUP` waits for ever, and every symptom of that is
  an absence -- the button does nothing, the log says nothing, and the code
  reads as though the case were handled. That is this project's characteristic
  failure with a helpful-looking name on it, and a fallback behind a working
  lookup is never exercised and never noticed.

  A fallback also does nothing for the host. A laptop has no `/dev/input` at
  all, so a fallback there is a path that does not exist handed to a caller
  that checks `File.exists?/1` before opening it. Nothing on the host path
  needs the string to look like a device node.

  So `find/1` answers `nil`, and says so out loud: a warning naming the device
  that is missing and every device that is present. What losing a device costs
  is the caller's own business -- no rocker is not a failed boot -- but no
  caller can reach the wrong one.

  There is deliberately no caching. This is called once per process at
  startup, the answer is two file reads, and a cache would be a second thing
  that can be stale.
  """

  require Logger

  @doc """
  The path of the input device called `name`, or `nil` when there is none.

  The success is logged at info because the boot log is then a record of what
  the numbering actually was on the firmware that booted, which is the one
  thing nobody can reconstruct afterwards.

  The failure is logged at warning, naming every device that *is* present,
  because a name that is not there means a device tree or a kernel config
  changed underneath this code -- and the only thing worse than a button that
  does nothing is a button that does nothing while the log stays quiet about
  which devices the kernel does have.
  """
  @spec find(String.t()) :: String.t() | nil
  def find(name) do
    devices = names()

    case Enum.find(devices, fn {_path, device_name} -> device_name == name end) do
      {path, _name} ->
        Logger.info("[input] #{name} is #{path}")
        path

      nil ->
        Logger.warning("[input] no input device named #{name}; present: #{inspect(devices)}")
        nil
    end
  end

  @doc """
  Every input device, as `{path, info}`.

  Empty when there are none and when asking is not possible, which are the
  same thing as far as any caller here is concerned.
  """
  @spec enumerate() :: [{String.t(), struct()}]
  def enumerate do
    InputEvent.enumerate()
  rescue
    error ->
      Logger.debug("[input] cannot enumerate: #{inspect(error)}")
      []
  catch
    :exit, reason ->
      Logger.debug("[input] cannot enumerate: #{inspect(reason)}")
      []
  end

  @doc """
  The names of every input device, for the diagnostics readout and for
  working out what a new kernel has done to the numbering.
  """
  @spec names() :: [{String.t(), String.t()}]
  def names, do: Enum.map(enumerate(), fn {path, info} -> {path, info.name} end)
end
