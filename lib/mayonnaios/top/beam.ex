defmodule MayonnaiOS.Top.Beam do
  @moduledoc """
  The BEAM's processes, read from the BEAM.

  `Process.list/0` plus one `Process.info/2` per process. Cheap enough to do
  every couple of seconds -- this firmware runs a few hundred processes -- and
  it needs nothing that is not already in the VM, so unlike the OS half there
  is no seam to inject and no way for the reading to be absent.

  ## What stands in for CPU

  The scheduler does not account CPU time per process, but every process
  counts its reductions -- roughly, function calls -- and a process that is
  burning a core is burning reductions. So the activity column is the
  reduction delta between two samples, computed by `rows/2` against the
  previous sample's `ref/1`, which is the same trick `etop` uses. The first
  sample has nothing to diff against and the column is `nil`; a cumulative
  count in that slot would rank every old process over every busy one.

  ## Naming a process

  A registered name is the name. For the rest, `:proc_lib.translate_initial_call/1`
  digs the real entry point out of the process dictionary -- without it every
  GenServer in the VM is `:proc_lib.init_p/5`, which distinguishes nothing.
  A process that dies mid-question, or one whose dictionary cannot be read,
  falls back to its pid, because a row that crashes the sampler is a screen
  that dies exactly when someone is watching a leak.
  """

  @type row :: %{
          pid: pid(),
          name: String.t(),
          reds: non_neg_integer(),
          mem: non_neg_integer(),
          mq: non_neg_integer()
        }

  @doc """
  One reading: every process the VM will answer for.

  A process that exits between `Process.list/0` and its `Process.info/2` --
  which happens, that is what processes do -- answers `nil` and is dropped
  rather than crashing the sample.
  """
  @spec sample() :: [row()]
  def sample do
    for pid <- Process.list(),
        info = Process.info(pid, [:registered_name, :reductions, :memory, :message_queue_len]),
        info != nil do
      %{
        pid: pid,
        name: name(pid, info[:registered_name]),
        reds: info[:reductions],
        mem: info[:memory],
        mq: info[:message_queue_len]
      }
    end
  end

  @doc """
  The rows for one sample, with the activity column computed against `prev`.

  `prev` is the `ref/1` of the previous sample, or `nil`. The column is `nil`
  for a pid the previous sample did not have -- including every pid on the
  first sample -- and for a count that went down, which is the VM reusing a
  pid for a new process.
  """
  @spec rows([row()], map() | nil) :: [map()]
  def rows(sample, prev) do
    Enum.map(sample, fn p ->
      cpu =
        case prev && prev[p.pid] do
          old when is_integer(old) and old <= p.reds -> p.reds - old
          _ -> nil
        end

      Map.put(p, :cpu, cpu)
    end)
  end

  @doc "What the next sample's deltas are computed against."
  @spec ref([row()]) :: map()
  def ref(sample), do: Map.new(sample, &{&1.pid, &1.reds})

  @doc "The line above the table: counts, the run queue, and the VM's memory."
  @spec header([row()]) :: map()
  def header(sample) do
    %{
      count: length(sample),
      run_queue: :erlang.statistics(:run_queue),
      memory: %{
        total: :erlang.memory(:total),
        processes: :erlang.memory(:processes),
        binary: :erlang.memory(:binary)
      }
    }
  end

  # `Process.info/2` answers `{:registered_name, []}` for a process with no
  # name, so an atom here really is a name.
  defp name(_pid, name) when is_atom(name) and name != nil, do: inspect(name)

  defp name(pid, _unregistered) do
    case :proc_lib.translate_initial_call(pid) do
      {mod, fun, arity} -> "#{inspect(mod)}.#{fun}/#{arity}"
      _other -> pid_string(pid)
    end
  rescue
    _ -> pid_string(pid)
  catch
    :exit, _ -> pid_string(pid)
  end

  defp pid_string(pid), do: pid |> :erlang.pid_to_list() |> to_string()
end
