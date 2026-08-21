defmodule MayonnaiOS.Application do
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
    #     MayonnaiOS.start_ui()
    #
    # Set `config :mayonnaios, autostart_ui: true` once it is known good.
    children =
      if Application.get_env(:mayonnaios, :autostart_ui, false) do
        # fbcon owns /dev/fb0 too, and repaints over the UI on every kernel
        # message. Release it before Scenic draws, or the scene appears for a
        # few seconds and is then buried under scrolling kernel log.
        MayonnaiOS.Console.release()
        [{Scenic, [Application.get_env(:mayonnaios, :viewport)]}]
      else
        []
      end ++ [controller_sessions()] ++ target_children()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: MayonnaiOS.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Empty until someone starts the controller app, and on the host as well as
  # on the device: an empty DynamicSupervisor is one process and no radio, and
  # having it everywhere means `MayonnaiOS.Controller.start/0` fails on a
  # laptop with the bind error rather than with "no such supervisor", which is
  # a much less interesting thing to be told.
  defp controller_sessions, do: MayonnaiOS.Controller.sessions()

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
        MayonnaiOS.Heartbeat,

        # Something on the panel as soon as there is a panel to put it on. It
        # polls for /dev/fb0 in its own process rather than blocking the
        # supervisor, because the framebuffer does not exist until the panel
        # module binds -- about two and a half seconds after the BEAM starts.
        # So placing it early costs nothing, and waiting for it would cost
        # everything after it.
        MayonnaiOS.Splash,

        # The way back in when WiFi does not come up. Nothing populates USB
        # configfs at boot, so without this usb0 never appears.
        MayonnaiOS.USBGadget,

        # Takes the mixer to 0% and mutes it, so the device starts silent by
        # decision rather than by inheritance. The hardware happens to power
        # on that way too -- DAC and Line Out switched off, no ALSA state to
        # restore -- which is exactly why it is worth setting.
        MayonnaiOS.Audio.Startup,

        # Collects battery, thermal, RTC, Bluetooth and mixer readings, and
        # owns the volume keys and the headphone-jack switch. Before the
        # Launcher, so the readout has data the moment the scene is opened.
        MayonnaiOS.Diagnostics,

        # Mounts the games card. Before Cores and the web server, because both
        # report on what is available and the card is part of the answer.
        # Tolerates no card, an unknown filesystem, and an existing mount.
        MayonnaiOS.GamesCard,

        # Relinks /root/retroarch/cores from the RetroArch bundle and the
        # installed core bundles. Before the web server, so the first page
        # load reports what is really there.
        MayonnaiOS.Cores.Startup,

        # The upload page. Last of the services because nothing else waits on
        # it: a device with no web server is still a console, and one whose
        # boot stopped at the web server is not.
        MayonnaiOS.Web,

        # A launches the selected program, Menu goes back to the home screen,
        # X opens the diagnostics readout, Select+Menu powers off.
        MayonnaiOS.Launcher
      ] ++ boot_diagnostics()
    end

    # Last, because it sleeps 15 s and then 75 s before writing: it is
    # reporting on a boot that has already happened, and must not delay
    # anything that makes the device reachable.
    defp boot_diagnostics() do
      if Application.get_env(:mayonnaios, :boot_diagnostics, true) do
        [MayonnaiOS.BootDiagnostics]
      else
        []
      end
    end
  end
end
