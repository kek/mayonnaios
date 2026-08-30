defmodule MayonnaiOS.Led.Monitor do
  @moduledoc """
  Arbitrates the requested LED state with battery state.

  The launcher still asks for `:running` and `:sleeping`; this process keeps
  that request while `MayonnaiOS.Status` supplies battery readings. Entering
  low battery at 20% and leaving it at 30% prevents a fuel-gauge reading near
  the boundary from changing the LED every poll.
  """

  use GenServer

  alias MayonnaiOS.{Led, Power, Status}

  @low_percent 20
  @clear_percent 30

  defstruct base: :starting, low_battery: false, drawn: nil, status: Status

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec set(Led.state()) :: :ok | {:error, File.posix()}
  def set(state), do: GenServer.call(__MODULE__, {:set, state})

  @impl GenServer
  def init(opts) do
    status = Keyword.get(opts, :status, Status)
    if status, do: Status.subscribe(status)

    state = %__MODULE__{status: status}
    {_result, state} = draw(state)
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:set, base}, _from, state) do
    {result, state} = state |> Map.put(:base, base) |> draw()
    {:reply, result, state}
  end

  @impl GenServer
  def handle_info({:mayonnaios_status, reading}, state) do
    state = %{state | low_battery: low_battery?(state.low_battery, reading)}
    {_result, state} = draw(state)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp low_battery?(was_low, %{battery: %{value: values, error: nil}})
       when is_map(values) do
    case {Power.state(values), Map.get(values, :capacity)} do
      {state, capacity}
      when state in [:discharging, :not_charging] and is_integer(capacity) ->
        if was_low, do: capacity < @clear_percent, else: capacity <= @low_percent

      _other ->
        false
    end
  end

  defp low_battery?(_was_low, _reading), do: false

  defp effective(%{base: :failure}), do: :failure

  defp effective(%{base: base, low_battery: true}) when base in [:running, :sleeping],
    do: :low_battery

  defp effective(%{base: base}), do: base

  defp draw(state) do
    next = effective(state)

    if next == state.drawn do
      {:ok, state}
    else
      {Led.write_state(next), %{state | drawn: next}}
    end
  end
end
