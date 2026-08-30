defmodule MayonnaiOS.Clock do
  @moduledoc """
  Reports whether network time has synchronized in this boot.

  `nerves_time` is a target dependency through `nerves_pack`; the module is
  absent on a host development machine. Keeping that distinction explicit
  lets Diagnostics say `unavailable` on a laptop and `never synchronized` on
  a device whose clock has not yet been established.
  """

  @type status :: :synchronized | :never_synchronized | :unavailable

  @spec status((-> boolean() | :unavailable)) :: status()
  def status(checker \\ &nerves_time_status/0) do
    case checker.() do
      true -> :synchronized
      false -> :never_synchronized
      :unavailable -> :unavailable
    end
  end

  @spec synchronized?((-> boolean() | :unavailable)) :: boolean()
  def synchronized?(checker \\ &nerves_time_status/0), do: status(checker) == :synchronized

  defp nerves_time_status do
    if Code.ensure_loaded?(NervesTime) and function_exported?(NervesTime, :synchronized?, 0) do
      apply(NervesTime, :synchronized?, [])
    else
      :unavailable
    end
  rescue
    _error -> false
  catch
    :exit, _reason -> false
  end
end
