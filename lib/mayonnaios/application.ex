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
      [status()] ++
        viewport() ++
        [controller_sessions(), file_manager_sessions(), pairing_sessions()] ++
        target_children()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: MayonnaiOS.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp viewport do
    if Application.get_env(:mayonnaios, :autostart_ui, false) do
      # fbcon owns /dev/fb0 too, and repaints over the UI on every kernel
      # message. Release it before Scenic draws, or the scene appears for a
      # few seconds and is then buried under scrolling kernel log.
      MayonnaiOS.Console.release()
      [{Scenic, [Application.get_env(:mayonnaios, :viewport)]}]
    else
      []
    end
  end

  # The battery, WiFi and clock readings behind the shared top bar. On the
  # host as well as on the device, and not in `target_children/0` with the
  # other pollers, because the UI is run on a laptop during development and a
  # bar with no reader behind it would spend that whole session saying "no
  # reading" -- which is true, and not what anyone is trying to look at.
  #
  # First in the list, ahead of Scenic, so the bar the root scene mounts has
  # something to subscribe to at boot. Order is not the only thing keeping
  # that working -- the bar knocks again whenever its reading has gone stale,
  # which is also what recovers it if this process is restarted -- but a
  # subscription that succeeds first time is one less thing to explain.
  #
  # It is a poller, not a device: nothing else waits on it, and if it dies the
  # panel says so rather than going blank.
  defp status, do: MayonnaiOS.Status

  # Empty until someone starts the controller app, and on the host as well as
  # on the device: an empty DynamicSupervisor is one process and no radio, and
  # having it everywhere means `MayonnaiOS.Controller.start/0` fails on a
  # laptop with the bind error rather than with "no such supervisor", which is
  # a much less interesting thing to be told.
  defp controller_sessions, do: MayonnaiOS.Controller.sessions()

  # The same arrangement for the file manager, and for the same reason: the
  # launcher starts it from the process that owns the gamepad, so it must not
  # be linked to that process. Empty until someone opens it.
  defp file_manager_sessions, do: MayonnaiOS.FileManager.sessions()

  # The same arrangement for the Bluetooth devices app, and a second empty
  # DynamicSupervisor rather than a shared one on purpose: the two apps want
  # hci0 and cannot both have it, and a single supervisor holding both would
  # make that collision look like a supervision decision instead of what it
  # is -- one radio. Starting the second while the first runs fails on
  # `MayonnaiOS.Bluetooth.Host`'s registered name, which is a reason the panel
  # can print.
  defp pairing_sessions, do: MayonnaiOS.Pairing.sessions()

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
