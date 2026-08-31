defmodule MayonnaiOS.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Fail with the missing board fact named, before starting any process that
    # could otherwise degrade into a silent input, LED or power-supply fault.
    MayonnaiOS.Device.load!()

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
      signs_of_life() ++
        [status()] ++
        led_monitor() ++
        viewport() ++
        [controller_sessions(), pairing_sessions(), pickle_sessions()] ++
        [
          top_sessions(),
          update_sessions(),
          backup_sessions(),
          moonlight_sessions(),
          wifi_sessions()
        ] ++
        target_children()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: MayonnaiOS.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        {:ok, pid}

      error ->
        # Blinking red, set before the error propagates: the BEAM is about to
        # exit and erlinit to reboot, and this is the only signal that failure
        # gives on a device whose panel never came up.
        MayonnaiOS.Led.set(:failure)
        error
    end
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

  # The same arrangement for the Bluetooth devices app, and a second empty
  # DynamicSupervisor rather than a shared one on purpose: the two apps want
  # hci0 and cannot both have it, and a single supervisor holding both would
  # make that collision look like a supervision decision instead of what it
  # is -- one radio. Starting the second while the first runs fails on
  # `MayonnaiOS.Bluetooth.Host`'s registered name, which is a reason the panel
  # can print.
  defp pairing_sessions, do: MayonnaiOS.Pairing.sessions()

  # The same arrangement for the process readout: empty until a menu row
  # starts it, everywhere, so `MayonnaiOS.Top.start(:beam)` works on a laptop.
  defp top_sessions, do: MayonnaiOS.Top.sessions()

  # The registry and DynamicSupervisor running pickles live under, empty
  # until one is started. Everywhere for the same reason as the others: the
  # web API and the console should fail with "no such pickle" on a laptop,
  # not with "no such supervisor".
  defp pickle_sessions, do: MayonnaiOS.Pickles.sessions()

  # The "Software update" app's DynamicSupervisor, empty until the row is
  # opened -- same arrangement as the other apps, so `MayonnaiOS.Update.App`
  # works on a laptop and fails with "no such supervisor" rather than an
  # exception if it is ever started before this line runs.
  defp update_sessions, do: MayonnaiOS.Update.App.sessions()

  # The user-data backup app is also temporary and starts only from System.
  defp backup_sessions, do: MayonnaiOS.Backup.App.sessions()

  # The Moonlight settings screen's DynamicSupervisor, empty until the row is
  # opened -- same arrangement as the other apps, so
  # `MayonnaiOS.Moonlight.App` works on a laptop and fails with "no such
  # supervisor" rather than an exception if it is ever started before this
  # line runs.
  defp moonlight_sessions, do: MayonnaiOS.Moonlight.App.sessions()

  # The WiFi settings app's DynamicSupervisor, empty until the row is opened.
  # Everywhere rather than only on the target, like the others: on a laptop
  # `MayonnaiOS.WiFi.App.start/0` then runs and the screen says there is no
  # radio, which is a more useful thing to be told than "no such supervisor"
  # -- and it is the only way to look at the screen without holding the
  # device.
  defp wifi_sessions, do: MayonnaiOS.WiFi.App.sessions()

  # List all child processes to be supervised
  if Mix.target() == :host do
    defp signs_of_life(), do: []
    defp led_monitor(), do: []

    defp target_children() do
      if Application.get_env(:mayonnaios, :host_runtime, false) do
        MayonnaiOS.HostRuntime.children()
      else
        []
      end
    end
  else
    # Starts after Status so its first subscription gets a battery reading.
    # The direct :starting write remains ahead of both in signs_of_life/0;
    # this process is the arbiter once normal supervision is available.
    defp led_monitor(), do: [MayonnaiOS.Led.Monitor]

    # The two children that say the software is alive, at the very front of
    # the tree -- ahead of Scenic and ahead of every poller.
    #
    # Both are free to start: the LED is one sysfs write, and the splash is a
    # Task that polls for /dev/fb0 in its own process. Neither can hold up
    # what follows, so there is nothing to weigh against being first.
    #
    # Being first is worth something twice over. The amber LED is the only
    # signal that survives a UI which fails to start, and the earlier it is
    # set the more of the boot it covers. And the splash and Scenic are both
    # waiting for the same framebuffer, so whichever starts second is the one
    # that draws second -- with the splash behind Scenic, a slow first frame
    # could put the wordmark on top of the home screen rather than before it.
    defp signs_of_life() do
      [
        # Earliest possible sign of life, and the only one that survives a UI
        # that fails to start. Needs nothing but sysfs.
        {MayonnaiOS.Led, :starting},

        # Something on the panel as soon as there is a panel to put it on. It
        # polls for /dev/fb0 in its own process rather than blocking the
        # supervisor, because the framebuffer does not exist until the panel
        # driver probes.
        MayonnaiOS.Splash
      ]
    end

    defp target_children() do
      # Order is deliberate, and it is about diagnosing a boot that fails.
      # Each of these is a way of finding out what happened when the one after
      # it never runs, so the cheapest and most reliable goes first. The LED
      # and the splash come before all of it, in `signs_of_life/0`.
      [
        # The way back in when WiFi does not come up. Nothing populates USB
        # configfs at boot, so without this usb0 never appears.
        MayonnaiOS.USBGadget,

        # Takes /root out of discard mode. Ahead of everything that writes to
        # it, because the discards this stops are what the writes trigger --
        # but behind the LED, the splash and the gadget, which are there to
        # make a failing boot diagnosable and should not be displaced by a
        # repair.
        MayonnaiOS.AppPartition.Startup,

        # Takes the mixer to 0% with the output path switched on, so the
        # device starts silent by decision rather than by inheritance -- and
        # so "silent" means the volume is down rather than the speaker being
        # disconnected. The hardware powers on with the path *closed*, which
        # is silent in the way that makes every audio program fail with EIO,
        # so this step is now the thing that makes audio work at all rather
        # than a tidy restatement of a default. See MayonnaiOS.Audio.
        MayonnaiOS.Audio.Startup,

        # The volume rocker. After Audio.Startup, because it starts believing
        # the mixer is silent and that is the process that makes it so.
        MayonnaiOS.Volume,

        # Collects battery, thermal, RTC, Bluetooth and mixer readings, and
        # reads the volume keys and the headphone-jack switch. Before the
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

        # Starts the pickles whose manifests ask for it. After the partition
        # repair (their code and state live there), before the web server, so
        # the first page load reports what is really running.
        MayonnaiOS.Pickles.Startup,

        # The upload page. Last of the services because nothing else waits on
        # it: a device with no web server is still a console, and one whose
        # boot stopped at the web server is not.
        MayonnaiOS.Web,

        # A launches the selected program, Menu goes back to the home screen,
        # X opens the diagnostics readout, the power button turns the backlight
        # off until any button is pressed, and Select+Menu powers off.
        MayonnaiOS.Launcher,

        # Solid green. After the launcher, so that the LED going solid means
        # every child above came up -- which is the whole claim it makes.
        {MayonnaiOS.Led, :running}
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
