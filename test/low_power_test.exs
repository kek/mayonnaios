defmodule MayonnaiOS.LowPowerTest do
  use ExUnit.Case, async: false

  alias MayonnaiOS.LowPower
  alias MayonnaiOS.LowPower.{Cpus, Governor, Radio, Renderer}

  # Two of the four steps are files, which is the whole reason they are
  # testable on a laptop: point :cpu_dir and :cpufreq_dir at a temp tree and
  # the same code the device runs writes into it. The other two are not, and
  # the notes in their describe blocks say what a green run here has and has
  # not established about them.
  #
  # What no test here can check is whether any of it saves power. That is a
  # reading of /sys/class/power_supply/axp20x-battery/current_now taken with
  # the panel dark, and only the device answers it.

  setup do
    root = Path.join(System.tmp_dir!(), "lowpower-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    # config/host.exs turns the measures off, so that a suite run on a Linux
    # machine cannot offline that machine's cores. Everything below points the
    # sysfs paths at `root` first, so turning them on here reaches nothing
    # real.
    Application.put_env(:mayonnaios, :low_power_sleep, true)

    on_exit(fn ->
      File.rm_rf(root)

      for key <- [:cpu_dir, :cpufreq_dir, :low_power_sleep, :viewport, :wifi_interface] do
        Application.delete_env(:mayonnaios, key)
      end
    end)

    %{root: root}
  end

  # A sysfs-shaped tree: cpu0 has no `online` file, which is what arm64 does
  # for the boot CPU and the reason nothing here ever tries to offline it.
  defp fake_cpus(root, count) do
    dir = Path.join(root, "cpu")
    File.mkdir_p!(Path.join(dir, "cpu0"))

    for n <- 1..(count - 1) do
      File.mkdir_p!(Path.join(dir, "cpu#{n}"))
      File.write!(Path.join([dir, "cpu#{n}", "online"]), "1\n")
    end

    Application.put_env(:mayonnaios, :cpu_dir, dir)
    dir
  end

  defp fake_policies(root, governors) do
    dir = Path.join(root, "cpufreq")

    for {name, governor} <- governors do
      File.mkdir_p!(Path.join(dir, name))
      File.write!(Path.join([dir, name, "scaling_governor"]), governor <> "\n")
    end

    Application.put_env(:mayonnaios, :cpufreq_dir, dir)
    dir
  end

  defp online(dir, n), do: dir |> Path.join("cpu#{n}/online") |> File.read!() |> String.trim()

  defp governor(dir, p),
    do: dir |> Path.join("#{p}/scaling_governor") |> File.read!() |> String.trim()

  describe "the cores" do
    test "go offline and come back", %{root: root} do
      dir = fake_cpus(root, 4)

      undo = Cpus.enter()
      assert online(dir, 1) == "0"
      assert online(dir, 2) == "0"
      assert online(dir, 3) == "0"

      assert Cpus.leave(undo) == :ok
      assert online(dir, 1) == "1"
      assert online(dir, 2) == "1"
      assert online(dir, 3) == "1"
    end

    test "leave cpu0 alone, having no file to write", %{root: root} do
      dir = fake_cpus(root, 4)

      Cpus.enter()

      refute File.exists?(Path.join(dir, "cpu0/online"))
    end

    test "a core that was already offline stays offline afterwards", %{root: root} do
      # The reason `enter/0` reads before it writes: restoring a hardcoded "1"
      # would quietly bring back a core that somebody had taken down on
      # purpose, and this device has no way to say so afterwards.
      dir = fake_cpus(root, 4)
      File.write!(Path.join(dir, "cpu2/online"), "0\n")

      undo = Cpus.enter()
      Cpus.leave(undo)

      assert online(dir, 1) == "1"
      assert online(dir, 2) == "0"
      assert online(dir, 3) == "1"
    end

    test "an absent directory is nothing to do, not a failure" do
      Application.put_env(:mayonnaios, :cpu_dir, "/nonexistent/dir/cpu")
      assert Cpus.enter() == :noop
    end

    test "a directory with no online files is nothing to do", %{root: root} do
      dir = Path.join(root, "cpu")
      File.mkdir_p!(Path.join(dir, "cpu0"))
      Application.put_env(:mayonnaios, :cpu_dir, dir)

      assert Cpus.enter() == :noop
    end
  end

  describe "the governor" do
    test "goes to powersave and back to what each policy had", %{root: root} do
      # Two policies with different governors, because restoring a single
      # remembered value across both is the mistake this shape prevents.
      dir = fake_policies(root, [{"policy0", "ondemand"}, {"policy4", "userspace"}])

      undo = Governor.enter()
      assert governor(dir, "policy0") == "powersave"
      assert governor(dir, "policy4") == "powersave"

      assert Governor.leave(undo) == :ok
      assert governor(dir, "policy0") == "ondemand"
      assert governor(dir, "policy4") == "userspace"
    end

    test "is nothing to do on this board today" do
      # /sys/devices/system/cpu/cpufreq is empty on the RG40XXV: no policy at
      # all, because sun50i-cpufreq-nvmem is =m and nothing modprobes it. This
      # step is written to be a no-op until kek/nerves_system_rg40xxv#6 lands,
      # and this is the test that says the no-op is intended rather than a bug.
      Application.put_env(:mayonnaios, :cpufreq_dir, "/nonexistent/dir/cpufreq")
      assert Governor.enter() == :noop
    end

    test "a policy directory with no governor file is nothing to do", %{root: root} do
      dir = Path.join(root, "cpufreq")
      File.mkdir_p!(Path.join(dir, "policy0"))
      Application.put_env(:mayonnaios, :cpufreq_dir, dir)

      assert Governor.enter() == :noop
    end
  end

  describe "the radio" do
    test "is nothing to do without VintageNet" do
      # VintageNet is a target-only dependency, so this is the only thing a
      # host run establishes about this step: that its absence is ordinary and
      # produces no undo entry. Whether `deconfigure(persist: false)` really
      # leaves the saved WiFi credentials alone is checkable on the device and
      # nowhere else, and it is the single most important property here -- a
      # persisting deconfigure would turn one press of the power button into
      # "the handheld forgot my WiFi".
      refute Code.ensure_loaded?(VintageNet)
      assert Radio.enter() == :noop
    end

    test "names the interface from configuration" do
      assert Radio.interface() == "wlan0"

      Application.put_env(:mayonnaios, :wifi_interface, "wlan1")
      assert Radio.interface() == "wlan1"
    end
  end

  describe "the renderer" do
    test "is nothing to do with no viewport running" do
      # No viewport is started by this suite, so this is what a host run can
      # say. That a driver started again by `leave/1` redraws the current
      # scene -- rather than coming up on an empty framebuffer -- is a
      # property of Scenic on the device, and is listed as untested in the
      # pull request for that reason.
      assert Renderer.enter() == :noop
    end

    test "takes the viewport name from the same config Scenic is started with" do
      # One place where the name is written down. A viewport renamed in
      # config/target.exs must not need a second edit here.
      assert Renderer.viewport_name() == :main_viewport

      Application.put_env(:mayonnaios, :viewport, name: :other_viewport)
      assert Renderer.viewport_name() == :other_viewport
    end

    test "falls back to the default name when there is no viewport config" do
      Application.put_env(:mayonnaios, :viewport, [])
      assert Renderer.viewport_name() == :main_viewport
    end
  end

  describe "entering and leaving" do
    test "returns an undo list that puts everything back", %{root: root} do
      cpus = fake_cpus(root, 4)
      policies = fake_policies(root, [{"policy0", "ondemand"}])

      undo = LowPower.enter()

      assert online(cpus, 1) == "0"
      assert governor(policies, "policy0") == "powersave"

      assert LowPower.leave(undo) == :ok
      assert online(cpus, 1) == "1"
      assert governor(policies, "policy0") == "ondemand"
    end

    test "leaves out the steps that had nothing to do", %{root: root} do
      # Only the cores exist here; the other three no-op. An undo list with an
      # entry for a step that never ran is an entry `leave/1` would act on.
      fake_cpus(root, 4)

      assert [{Cpus, _}] = LowPower.enter()
    end

    test "one failing step does not stop the others", %{root: root} do
      # The failure being defended against is a device stuck half-asleep. A
      # cpufreq directory that is not there must not cost the cores their
      # chance to go offline.
      cpus = fake_cpus(root, 4)
      Application.put_env(:mayonnaios, :cpufreq_dir, "/nonexistent/dir/cpufreq")

      LowPower.enter()

      assert online(cpus, 1) == "0"
    end

    test "an empty undo list is a no-op rather than a crash" do
      # What a Launcher restarted while asleep hands it: the process came back
      # knowing nothing, which is the recoverable state and the reason none of
      # this is persisted.
      assert LowPower.leave([]) == :ok
    end

    test "is off entirely when configuration says so", %{root: root} do
      # The switch exists because taking wlan0 down ends any SSH session that
      # arrived over it, and somebody debugging sleep over WiFi wants a way to
      # say no.
      cpus = fake_cpus(root, 4)
      Application.put_env(:mayonnaios, :low_power_sleep, false)

      assert LowPower.enter() == []
      assert online(cpus, 1) == "1"
    end

    test "defaults to on where nothing has an opinion" do
      # The default is what a target build gets if config/target.exs ever
      # loses its line; on a host build config/host.exs sets it false on
      # purpose, and the setup above overrides that for this file.
      Application.delete_env(:mayonnaios, :low_power_sleep)
      assert LowPower.enabled?()

      Application.put_env(:mayonnaios, :low_power_sleep, false)
      refute LowPower.enabled?()
    end
  end
end
