defmodule MayonnaiOS.Input do
  @moduledoc """
  Finding an input device by what it is rather than by what it is numbered.

  `/dev/input/eventN` is assigned in probe order, and probe order is not a
  promise. Three devices on this board were reliably `event0`, `event1` and
  `event2` for as long as there were only three, and every caller wrote those
  paths down. Adding a fourth -- the analog stick, once the BSP describes it
  -- changes the number of things racing to register, and the failure that
  produces is the worst-shaped one available: the launcher opens `event0`,
  gets the joystick, and the handheld boots with no buttons and no way to
  leave whatever is on the screen.

  So the device is looked up by the name its driver gives it, which comes
  from the device tree and changes only when someone changes it on purpose:

      gpio-keys-gamepad             the buttons and the D-pad
      gpio-keys-volume              the volume rocker
      H616 Audio Codec Headphone Jack   the jack switch

  ## The fallback is the point

  `find/2` takes the path to use when the name is not found, and that path is
  the one the caller used to hard-code. So this is strictly safer than what
  it replaces: when enumeration works and the name is there, the answer is
  right even if the numbering moved; when enumeration finds nothing -- on a
  laptop, where there is no `/dev/input` at all -- the caller gets exactly
  the behaviour it had before, which is to try the old path and degrade
  gracefully when it does not open.

  There is deliberately no caching. This is called once per process at
  startup, the answer is two file reads, and a cache would be a second thing
  that can be stale.
  """

  require Logger

  @doc """
  The path of the input device called `name`, or `fallback`.

  Enumeration is wrapped because `InputEvent.enumerate/0` reaches for a port
  binary that is only built on Linux; on a development machine it can raise
  rather than return an empty list, and a raise here would take down whichever
  process was merely trying to find its buttons.
  """
  @spec find(String.t(), String.t()) :: String.t()
  def find(name, fallback) do
    case Enum.find(enumerate(), fn {_path, info} -> info.name == name end) do
      {path, _info} ->
        if path != fallback do
          # Worth an info line rather than a debug one: this is the moment
          # the numbering turned out not to be what the code assumed, and it
          # explains why a later log line names a device nobody configured.
          Logger.info("[input] #{name} is #{path}, not #{fallback}")
        end

        path

      nil ->
        fallback
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
