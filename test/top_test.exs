defmodule MayonnaiOS.TopTest do
  # Not async: the app is a named process.
  use ExUnit.Case, async: false

  alias MayonnaiOS.Top
  alias MayonnaiOS.Top.{Beam, Os}
  alias MayonnaiOS.Scene.Top, as: Scene

  # The buttons as InputEvent names them, not as the shell prints them.
  # Spelled out here rather than reused from the module under test: if these
  # ever disagree, the test is the thing that should notice.
  #
  #   shell Y = 307 -> :btn_x
  @y :btn_x
  @up :btn_dpad_up
  @down :btn_dpad_down
  @left :btn_dpad_left
  @right :btn_dpad_right
  @menu :btn_mode

  # input/1 is a cast and snapshot/0 is a call, so the call is ordered behind
  # the press and no test has to sleep.
  defp press(key, value \\ 1) do
    Top.input([{:ev_key, key, value}])
    Top.snapshot()
  end

  # A /proc/<pid>/stat line with the fields this app reads in their proc(5)
  # positions: state 3, utime 14, stime 15, rss 24 -- and a few more after,
  # because the real file does not stop where the interest does.
  defp stat_line(pid, comm, state, utime, stime, rss) do
    fields =
      [state] ++
        List.duplicate("0", 10) ++
        ["#{utime}", "#{stime}"] ++
        List.duplicate("0", 8) ++ ["#{rss}"] ++ List.duplicate("0", 5)

    "#{pid} (#{comm}) " <> Enum.join(fields, " ") <> "\n"
  end

  describe "parsing /proc" do
    test "an ordinary stat line" do
      assert {:ok, row} = Os.parse_stat(stat_line(42, "init", "S", 10, 5, 3))
      assert row == %{pid: 42, name: "init", state: "S", jiffies: 15, mem: 3 * 4096}
    end

    test "a comm with spaces and close-parens in it" do
      # Both real: tmux names its server "tmux: server", systemd's per-user
      # helper is "(sd-pam)". Splitting on whitespace or on the first paren
      # mis-parses each.
      assert {:ok, %{name: "tmux: server"}} =
               Os.parse_stat(stat_line(7, "tmux: server", "S", 1, 1, 1))

      assert {:ok, %{name: "(sd-pam)", state: "S"}} =
               Os.parse_stat(stat_line(8, "(sd-pam)", "S", 1, 1, 1))
    end

    test "garbage is an error rather than a row" do
      assert :error = Os.parse_stat("")
      assert :error = Os.parse_stat("not a stat line at all")
      assert :error = Os.parse_stat("12 (short) S 0 0")
    end

    test "total jiffies is the sum of the aggregate cpu line, idle included" do
      stat = "cpu  10 20 30 40\ncpu0 5 10 15 20\ncpu1 5 10 15 20\nintr 12345\n"
      assert Os.total_jiffies(stat) == 100
      assert Os.cpu_count(stat) == 2
    end

    test "a machine that lists no per-cpu lines still counts as one cpu" do
      assert Os.cpu_count("cpu  1 2 3\n") == 1
    end

    test "meminfo gives total and available in bytes" do
      text =
        "MemTotal:         510432 kB\nMemFree:           98000 kB\nMemAvailable:     301234 kB\n"

      assert Os.memory(text) == %{total: 510_432 * 1024, available: 301_234 * 1024}
    end
  end

  describe "the OS cpu column" do
    defp os_sample(total, jiffies) do
      %{
        total: total,
        cpus: 4,
        processes: [%{pid: 1, name: "init", state: "S", jiffies: jiffies, mem: 4096}],
        load: [],
        memory: %{total: nil, available: nil}
      }
    end

    test "is a delta between two samples, as percent of one core" do
      first = os_sample(1000, 100)
      second = os_sample(1400, 150)

      # 50 of the machine's 400 jiffies, on a 4-cpu machine: half a core.
      assert [%{cpu: 50.0}] = Os.rows(second, Os.ref(first))
    end

    test "is honest about not knowing" do
      # No previous sample; a pid the previous sample did not have; and a
      # count that went down, which is pid reuse.
      assert [%{cpu: nil}] = Os.rows(os_sample(1000, 100), nil)

      other = %{Os.ref(os_sample(500, 0)) | jiffies: %{99 => 1}}
      assert [%{cpu: nil}] = Os.rows(os_sample(1000, 100), other)

      reused = Os.ref(os_sample(500, 999))
      assert [%{cpu: nil}] = Os.rows(os_sample(1000, 100), reused)
    end
  end

  describe "the BEAM sampler" do
    test "names registered processes by their name" do
      Process.register(self(), :top_test_named)

      assert Enum.any?(Beam.sample(), &(&1.name == ":top_test_named"))
    after
      Process.unregister(:top_test_named)
    end

    test "the activity column is a reduction delta, nil on the first sample" do
      sample = Beam.sample()

      assert Enum.all?(Beam.rows(sample, nil), &(&1.cpu == nil))

      later = Beam.sample()
      rows = Beam.rows(later, Beam.ref(sample))
      me = Enum.find(rows, &(&1.pid == self()))

      # This process has burned reductions between the two samples -- it took
      # them. The exact number is nobody's business, but it exists.
      assert is_integer(me.cpu)
    end
  end

  describe "the app" do
    # The refresh clock is pinned far away so a tick cannot re-sample the VM
    # between a press and its assertion; refreshing has its own describe.
    setup do
      start_supervised!({Top, kind: :beam, refresh_ms: 60_000})
      :ok
    end

    test "a snapshot is one screen of a larger, sorted list" do
      snapshot = Top.snapshot()

      assert snapshot.kind == :beam
      assert snapshot.total > length(snapshot.rows)
      assert length(snapshot.rows) == 16
      assert snapshot.header.count == snapshot.total
    end

    test "the d-pad scrolls, clamped at both ends" do
      assert Top.snapshot().offset == 0
      assert press(@up).offset == 0

      assert press(@down).offset == 1
      # Autorepeat scrolls too, so a held direction walks the list.
      assert press(@down, 2).offset == 2

      assert press(@right).offset == 2 + 16

      # All the way down: clamped to the last full screen, not past it.
      last = Enum.reduce(1..1000, nil, fn _n, _acc -> press(@down) end)
      assert last.offset == last.total - 16
      assert press(@down).offset == last.offset

      assert press(@left).offset == last.offset - 16
    end

    test "Y flips the sort and goes back to the top" do
      press(@down)

      assert %{sort: :mem, offset: 0} = press(@y)

      # Sorted by memory means descending in it.
      mems = Enum.map(Top.snapshot().rows, & &1.mem)
      assert mems == Enum.sort(mems, :desc)

      assert %{sort: :cpu} = press(@y)
    end

    test "Menu and the face buttons change nothing" do
      before = Top.snapshot()

      assert press(@menu) == before
      assert press(:btn_a) == before
      assert press(:btn_b) == before
    end

    test "starting the other screen switches the running app over" do
      assert {:ok, _pid} = Top.start(:os)
      assert Top.snapshot().kind == :os
    end
  end

  describe "refreshing" do
    test "pushes a new snapshot to watchers, and deltas appear" do
      {:ok, pid} = Top.start_link(kind: :beam, refresh_ms: 30)
      Top.watch(self())

      assert_receive {:top, _first}, 1000
      assert_receive {:top, second}, 1000

      # By the second tick there is a previous sample, so the busy rows carry
      # a reduction delta.
      assert Enum.any?(second.rows, &is_integer(&1.cpu))

      GenServer.stop(pid)
    end
  end

  describe "the OS screen" do
    # A /proc a laptop can offer: the host this suite runs on has none.
    defp fixture do
      dir = Path.join(System.tmp_dir!(), "top-proc-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "12"))
      File.mkdir_p!(Path.join(dir, "340"))

      File.write!(
        Path.join(dir, "stat"),
        "cpu  100 0 100 800\ncpu0 50 0 50 400\ncpu1 50 0 50 400\n"
      )

      File.write!(Path.join(dir, "loadavg"), "0.42 0.38 0.31 2/189 12345\n")

      File.write!(
        Path.join(dir, "meminfo"),
        "MemTotal:         510432 kB\nMemAvailable:     301234 kB\n"
      )

      File.write!(Path.join([dir, "12", "stat"]), stat_line(12, "retroarch", "R", 50, 10, 2000))
      File.write!(Path.join([dir, "340", "stat"]), stat_line(340, "kworker/0:1", "I", 1, 0, 0))

      dir
    end

    test "reads processes, load and memory from a proc directory" do
      dir = fixture()
      {:ok, pid} = Top.start_link(kind: :os, proc: dir, refresh_ms: 60_000)

      snapshot = Top.snapshot()

      assert snapshot.kind == :os
      assert snapshot.error == nil
      assert snapshot.total == 2
      assert snapshot.header.cpus == 2
      assert snapshot.header.load == ["0.42", "0.38", "0.31"]
      assert snapshot.header.memory.total == 510_432 * 1024

      # Sorted: no deltas yet, so by memory within the nil-cpu tier --
      # retroarch's 2000 pages over the kworker's none.
      assert [%{name: "retroarch", state: "R"}, %{name: "kworker/0:1"}] = snapshot.rows

      assert %Scenic.Graph{} = Scene.graph(snapshot)

      GenServer.stop(pid)
      File.rm_rf!(dir)
    end

    test "a machine with no proc is a reading of its own, not a crash" do
      dir = Path.join(System.tmp_dir!(), "top-no-proc-#{System.unique_integer([:positive])}")
      {:ok, pid} = Top.start_link(kind: :os, proc: dir, refresh_ms: 60_000)

      snapshot = Top.snapshot()
      assert snapshot.error == :enoent
      assert snapshot.rows == []

      assert %Scenic.Graph{} = Scene.graph(snapshot)

      GenServer.stop(pid)
    end
  end

  describe "the panel" do
    setup do
      start_supervised!({Top, kind: :beam, refresh_ms: 60_000})
      :ok
    end

    test "every snapshot builds a graph, including the app not running" do
      assert %Scenic.Graph{} = Scene.graph(:stopped)
      assert %Scenic.Graph{} = Scene.graph(:stopped, :eusers)
      assert %Scenic.Graph{} = Scene.graph(Top.snapshot())
      assert %Scenic.Graph{} = Scene.graph(press(@y))
    end

    test "nothing is drawn in the strip reserved for the shared top bar" do
      for {y, primitive} <- placements(Scene.graph(Top.snapshot())) do
        assert y >= Scene.status_bar(),
               "#{inspect(primitive)} is at y=#{y}, inside the top #{Scene.status_bar()} px"
      end
    end

    test "the table says where in the list the window sits" do
      press(@down)
      words = texts(Scene.graph(Top.snapshot()))

      assert Enum.any?(words, &String.match?(&1, ~r/^2–17 of \d+, by reductions$/))
    end

    test "the header line carries the VM's own numbers" do
      words = texts(Scene.graph(Top.snapshot()))

      assert Enum.any?(words, &String.contains?(&1, "run queue"))
    end

    defp texts(graph) do
      Scenic.Graph.reduce(graph, [], fn
        %Scenic.Primitive{module: Scenic.Primitive.Text, data: data}, acc -> [data | acc]
        _primitive, acc -> acc
      end)
    end

    # Every primitive's y, except the full-screen background: the status bar
    # paints over that, and a screen with no background is not a screen.
    defp placements(graph) do
      Scenic.Graph.reduce(graph, [], fn
        %Scenic.Primitive{data: {640, 480}}, acc ->
          acc

        %Scenic.Primitive{} = primitive, acc ->
          case get_in(primitive.transforms, [:translate]) do
            {_x, y} -> [{y, primitive.module} | acc]
            _none -> acc
          end
      end)
    end
  end
end
