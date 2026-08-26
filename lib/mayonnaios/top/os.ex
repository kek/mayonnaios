defmodule MayonnaiOS.Top.Os do
  @moduledoc """
  The operating system's processes, read from `/proc`.

  Everything comes from four files: `/proc/stat` for the machine's total
  jiffies and its CPU count, `/proc/loadavg`, `/proc/meminfo`, and one
  `/proc/<pid>/stat` per process. No `ps`, no `top`: neither is in this image,
  and both are themselves just readers of these files.

  ## CPU percent needs two samples

  `/proc/<pid>/stat` gives cumulative jiffies, so a single reading says how
  much a process has used since it started -- for the BEAM, that is most of a
  boot's worth, which is not what "is it busy right now" asks. The percentage
  is a delta: this process's jiffies against the machine's, between two
  samples. `rows/2` takes the previous sample's `ref/1` and computes it;
  passed `nil` -- the first reading -- the column is `nil` and the panel says
  so rather than showing a since-boot number dressed up as a rate.

  The percent is of one core, `top`'s convention, so RetroArch pegging a core
  on this four-core SoC reads as 100 rather than 25.

  ## The comm field is hostile to naive parsing

  A process names itself in `stat` inside parentheses, and the name may
  contain spaces and close-parens -- `(tmux: server)`, `((sd-pam))`. Splitting
  on whitespace mis-parses those, so `parse_stat/1` takes the name as
  everything between the first `(` and the *last* `) `, which is what the
  kernel's own documentation prescribes.

  ## The paths are parameters

  `sample/1` takes the proc directory so a test can point it at a fixture --
  the host this suite runs on has no `/proc` at all, and the target cannot be
  in the test loop. On a machine without procfs the sample is an error, and
  the screen renders the reason rather than an empty list pretending to be a
  quiet machine.
  """

  # This board's kernel uses 4 KiB pages, and `rss` in stat is in pages.
  @page_bytes 4096

  @type row :: %{
          pid: pos_integer(),
          name: String.t(),
          state: String.t(),
          jiffies: non_neg_integer(),
          mem: non_neg_integer()
        }

  @type sample :: %{
          total: non_neg_integer(),
          cpus: pos_integer(),
          processes: [row()],
          load: [String.t()],
          memory: %{total: non_neg_integer() | nil, available: non_neg_integer() | nil}
        }

  @doc """
  One reading of the whole machine, or why there is none.

  A process that vanishes between the directory listing and the read of its
  `stat` -- which happens constantly, that is what processes do -- is simply
  absent from the list rather than an error.
  """
  @spec sample(Path.t()) :: {:ok, sample()} | {:error, term()}
  def sample(proc \\ "/proc") do
    case File.read(Path.join(proc, "stat")) do
      {:ok, stat} ->
        {:ok,
         %{
           total: total_jiffies(stat),
           cpus: cpu_count(stat),
           processes: processes(proc),
           load: load(proc),
           memory: read_memory(proc)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The rows for one sample, with the CPU column computed against `prev`.

  `prev` is the `ref/1` of the previous sample, or `nil` when there is none.
  The column is `nil` when it cannot be honest: no previous sample, a pid the
  previous sample did not have, or a pid whose jiffies went *down* -- which is
  pid reuse, a different process wearing a dead one's number.
  """
  @spec rows(sample(), map() | nil) :: [map()]
  def rows(%{processes: procs, total: total, cpus: cpus}, prev) do
    dtotal = if prev, do: total - prev.total, else: 0

    Enum.map(procs, fn p ->
      cpu =
        with true <- dtotal > 0,
             old when is_integer(old) <- prev.jiffies[p.pid],
             delta when delta >= 0 <- p.jiffies - old do
          Float.round(100.0 * cpus * delta / dtotal, 1)
        else
          _ -> nil
        end

      Map.put(p, :cpu, cpu)
    end)
  end

  @doc "What the next sample's deltas are computed against."
  @spec ref(sample()) :: map()
  def ref(%{total: total, processes: procs}) do
    %{total: total, jiffies: Map.new(procs, &{&1.pid, &1.jiffies})}
  end

  @doc "The line above the table: counts, load, and memory."
  @spec header(sample()) :: map()
  def header(sample) do
    %{
      count: length(sample.processes),
      cpus: sample.cpus,
      load: sample.load,
      memory: sample.memory
    }
  end

  # -- parsing, pure and public so the host tests can feed it strings ---------

  @doc """
  One `/proc/<pid>/stat` into a row, or `:error` for a line that is not one.

  See the moduledoc for the comm field; the numeric fields are indexed from
  proc(5): utime and stime are fields 14 and 15, rss is field 24, and after
  the close-paren split those are offsets 11, 12 and 21 with `state` at 0.
  """
  @spec parse_stat(String.t()) :: {:ok, row()} | :error
  def parse_stat(text) do
    with {:ok, pid, comm, rest} <- split_comm(String.trim(text)),
         fields = String.split(rest, " ", trim: true),
         [state | _rest] <- fields,
         {utime, ""} <- Integer.parse(Enum.at(fields, 11) || ""),
         {stime, ""} <- Integer.parse(Enum.at(fields, 12) || ""),
         {rss, ""} <- Integer.parse(Enum.at(fields, 21) || "") do
      {:ok,
       %{
         pid: pid,
         name: comm,
         state: state,
         jiffies: utime + stime,
         mem: max(rss, 0) * @page_bytes
       }}
    else
      _ -> :error
    end
  end

  @doc """
  The machine's total jiffies: the sum of every column on `/proc/stat`'s
  aggregate `cpu` line, idle included. That sum only ever grows, which is what
  makes it a denominator.
  """
  @spec total_jiffies(String.t()) :: non_neg_integer()
  def total_jiffies(stat_text) do
    case String.split(stat_text, "\n", parts: 2) do
      ["cpu " <> numbers | _] ->
        numbers
        |> String.split()
        |> Enum.reduce(0, fn field, acc ->
          case Integer.parse(field) do
            {n, ""} -> acc + n
            _ -> acc
          end
        end)

      _ ->
        0
    end
  end

  @doc """
  How many cores `/proc/stat` lists, floored at one so it can be multiplied
  and divided by without a guard at every use.
  """
  @spec cpu_count(String.t()) :: pos_integer()
  def cpu_count(stat_text) do
    stat_text
    |> String.split("\n")
    |> Enum.count(&Regex.match?(~r/^cpu\d+ /, &1))
    |> max(1)
  end

  @doc """
  Total and available memory in bytes, from a `/proc/meminfo` text.

  MemAvailable rather than MemFree, because free is what nothing has touched
  and available is what a new allocation could actually get -- the kernel
  counts reclaimable cache into the latter, and the latter is the number that
  answers "is this device short of memory".
  """
  @spec memory(String.t()) :: %{
          total: non_neg_integer() | nil,
          available: non_neg_integer() | nil
        }
  def memory(text) do
    %{total: meminfo_kb(text, "MemTotal"), available: meminfo_kb(text, "MemAvailable")}
  end

  defp meminfo_kb(text, key) do
    case Regex.run(~r/^#{key}:\s+(\d+) kB/m, text) do
      [_, kb] -> String.to_integer(kb) * 1024
      nil -> nil
    end
  end

  # -- reading -----------------------------------------------------------------

  defp processes(proc) do
    case File.ls(proc) do
      {:ok, entries} ->
        for name <- entries,
            Regex.match?(~r/^\d+$/, name),
            {:ok, stat} <- [File.read(Path.join([proc, name, "stat"]))],
            {:ok, row} <- [parse_stat(stat)] do
          row
        end

      {:error, _reason} ->
        []
    end
  end

  defp load(proc) do
    case File.read(Path.join(proc, "loadavg")) do
      {:ok, text} -> text |> String.split() |> Enum.take(3)
      {:error, _reason} -> []
    end
  end

  defp read_memory(proc) do
    case File.read(Path.join(proc, "meminfo")) do
      {:ok, text} -> memory(text)
      {:error, _reason} -> %{total: nil, available: nil}
    end
  end

  # The pid is everything before the first " (", the name everything up to the
  # *last* ") " -- see the moduledoc for the process names that make the
  # distinction matter.
  defp split_comm(text) do
    with [pid_s, rest] <- String.split(text, " (", parts: 2),
         {pid, ""} <- Integer.parse(pid_s),
         parts when length(parts) > 1 <- String.split(rest, ") ") do
      {:ok, pid, Enum.join(:lists.droplast(parts), ") "), List.last(parts)}
    else
      _ -> :error
    end
  end
end
