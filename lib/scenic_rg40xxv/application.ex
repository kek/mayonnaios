defmodule ScenicRg40xxv.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Scenic is started on demand rather than from the supervision tree.
    #
    # If it fails during boot the whole application fails, StartupGuard never
    # validates, and U-Boot reverts to the other partition on the next boot --
    # which loses both the device and the error message. Starting it by hand
    # over SSH keeps the failure readable:
    #
    #     ScenicRg40xxv.start_ui()
    #
    # Set `config :scenic_rg40xxv, autostart_ui: true` once it is known good.
    children =
      if Application.get_env(:scenic_rg40xxv, :autostart_ui, false) do
        # fbcon owns /dev/fb0 too, and repaints over the UI on every kernel
        # message. Release it before Scenic draws, or the scene appears for a
        # few seconds and is then buried under scrolling kernel log.
        ScenicRg40xxv.Console.release()
        [{Scenic, [Application.get_env(:scenic_rg40xxv, :viewport)]}]
      else
        []
      end ++ target_children()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ScenicRg40xxv.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # List all child processes to be supervised
  if Mix.target() == :host do
    defp target_children() do
      [
        # Children that only run on the host during development or test.
        # In general, prefer using `config/host.exs` for differences.
        #
        # Starts a worker by calling: Host.Worker.start_link(arg)
        # {Host.Worker, arg},
      ]
    end
  else
    defp target_children() do
      # Order is deliberate, and it is about diagnosing a boot that fails.
      # Each of these is a way of finding out what happened when the one after
      # it never runs, so the cheapest and most reliable goes first.
      [
        # Earliest possible sign of life, and the only one that survives a UI
        # that fails to start. Needs nothing but sysfs.
        ScenicRg40xxv.Heartbeat,

        # The way back in when WiFi does not come up. Nothing populates USB
        # configfs at boot, so without this usb0 never appears.
        ScenicRg40xxv.USBGadget,

        # Takes the mixer to 0% and mutes it, so the device starts silent by
        # decision rather than by inheritance. The hardware happens to power
        # on that way too -- DAC and Line Out switched off, no ALSA state to
        # restore -- which is exactly why it is worth setting.
        ScenicRg40xxv.Audio.Startup,

        # Collects battery, thermal, RTC, Bluetooth and mixer readings, and
        # owns the volume keys and the headphone-jack switch. Before the
        # Launcher, so the readout has data the moment the scene is opened.
        ScenicRg40xxv.Diagnostics,

        # Relinks /root/retroarch/cores from the RetroArch bundle and the
        # installed core bundles. Before the web server, so the first page
        # load reports what is really there.
        ScenicRg40xxv.Cores.Startup,

        # The upload page. Last of the services because nothing else waits on
        # it: a device with no web server is still a console, and one whose
        # boot stopped at the web server is not.
        ScenicRg40xxv.Web,

        # A launches the selected program, Menu goes back to the home screen,
        # X opens the diagnostics readout, Select+Menu powers off.
        ScenicRg40xxv.Launcher
      ] ++ boot_diagnostics()
    end

    # Last, because it sleeps 15 s and then 75 s before writing: it is
    # reporting on a boot that has already happened, and must not delay
    # anything that makes the device reachable.
    defp boot_diagnostics() do
      if Application.get_env(:scenic_rg40xxv, :boot_diagnostics, true) do
        [ScenicRg40xxv.BootDiagnostics]
      else
        []
      end
    end
  end
end
