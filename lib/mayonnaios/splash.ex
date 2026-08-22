defmodule MayonnaiOS.Splash do
  @moduledoc """
  Puts something on the panel as soon as there is a panel to put it on.

  ## Why this is drawn here rather than earlier

  It looks like a splash screen belongs in the bootloader, or in the kernel as
  `CONFIG_LOGO`. On this board neither is earlier in practice, because the
  panel is the constraint and not the software. Measured on hardware:

      2.32s   init starts
      2.78s   f2fs starts mounting /root
      5.73s   /root mounted
      7.10s   the BEAM starts
      9.47s   panel-mipi binds
      10.27s  console switches to the framebuffer

  The panel driver is a module (`CONFIG_DRM_PANEL_MIPI=m`) whose panel
  description is a firmware file, and erlinit loads it from `--pre-run-exec`
  *after* mounting `/root` -- so the display waits about three seconds behind
  an f2fs mount that has nothing to do with it. The BEAM is already running
  two and a half seconds before the panel exists.

  So Elixir is not the late part. Drawing from here lands within a few
  hundred milliseconds of the first moment the hardware can show anything, and
  if the panel is later made to come up early -- built in, with its firmware
  linked into the kernel image -- this same code starts appearing at around
  two seconds with no change.

  ## Kernel messages will scribble over it

  The kernel command line carries `console=tty0` and deliberately omits
  `quiet`, because during bring-up a silent screen could not be told apart
  from a screen that never came up. That decision was right and it is why boot
  messages scroll past. It also means fbcon owns this framebuffer and will
  print over anything drawn here.

  `quiesce_console/0` unbinds fbcon from the framebuffer before drawing, which
  stops that without touching the kernel command line, without a rebuild, and
  without giving up the messages -- they still go to `ttyS0` and to `dmesg`.
  It is best-effort: if the unbind fails, the splash is drawn anyway and the
  worst case is the status quo.
  """

  use Task, restart: :transient
  require Logger

  @fb "/dev/fb0"
  @sysfs "/sys/class/graphics/fb0"

  # Mayonnaise, and something dark enough to read on it.
  @background {0xF2, 0xE8, 0xC8}
  @ink {0x3A, 0x32, 0x26}

  # 5x7 glyphs, written as pictures rather than hex, so that a wrong pixel is
  # visible in review. Only the letters the wordmark needs.
  @glyphs %{
    ?M => ~w(#...# ##.## #.#.# #...# #...# #...# #...#),
    ?A => ~w(.###. #...# #...# ##### #...# #...# #...#),
    ?Y => ~w(#...# #...# .#.#. ..#.. ..#.. ..#.. ..#..),
    ?O => ~w(.###. #...# #...# #...# #...# #...# .###.),
    ?N => ~w(#...# ##..# #.#.# #..## #...# #...# #...#),
    ?I => ~w(##### ..#.. ..#.. ..#.. ..#.. ..#.. #####),
    ?S => ~w(.#### #.... #.... .###. ....# ....# ####.)
  }

  @word ~c"MAYONNAIOS"
  @glyph_w 5
  @glyph_h 7

  def start_link(opts \\ []), do: Task.start_link(__MODULE__, :run, [opts])

  @doc """
  Wait for the framebuffer, take the console off it, and draw.
  """
  def run(opts \\ []) do
    fb = Keyword.get(opts, :fb, @fb)
    sysfs = Keyword.get(opts, :sysfs, @sysfs)
    timeout = Keyword.get(opts, :timeout, 30_000)

    case await_framebuffer(fb, timeout) do
      :ok ->
        quiesce_console()
        {w, h} = geometry(sysfs)
        :ok = File.write(fb, render(w, h))
        Logger.info("[splash] drew #{w}x#{h}")

      {:error, :timeout} ->
        # Not fatal. A device with no panel still boots, still has SSH, and
        # still runs games over HDMI-less debugging -- refusing to start
        # because a decoration is missing would be the worse failure.
        Logger.warning("[splash] #{fb} never appeared; skipping")
    end
  end

  @doc """
  The framebuffer's dimensions, read from sysfs rather than assumed.

  Falls back to this panel's 640x480 if sysfs does not say, because a wrong
  guess here writes a sheared image rather than failing, and a sheared image
  is harder to recognise as a configuration problem than a correct one.
  """
  def geometry(sysfs \\ @sysfs) do
    with {:ok, raw} <- File.read(Path.join(sysfs, "virtual_size")),
         [w, h] <- raw |> String.trim() |> String.split(","),
         {w, ""} <- Integer.parse(w),
         {h, ""} <- Integer.parse(h) do
      {w, h}
    else
      _ -> {640, 480}
    end
  end

  @doc """
  The whole framebuffer as iodata: XRGB8888, little-endian, so each pixel is
  blue, green, red, pad.
  """
  def render(width, height) do
    bg = pixel(@background)
    blank = :binary.copy(bg, width)

    scale = scale_for(width)
    # Each glyph is followed by one blank column; the last one is dropped so
    # the wordmark centres on its ink rather than on a trailing space.
    columns = length(@word) * (@glyph_w + 1) - 1
    text_w = columns * scale
    text_h = @glyph_h * scale
    left = max(div(width - text_w, 2), 0)
    top = div(height - text_h, 2)

    for y <- 0..(height - 1) do
      row = y - top

      if row >= 0 and row < text_h do
        text_row(width, left, div(row, scale), scale, bg)
      else
        blank
      end
    end
  end

  # One scanline crossing the wordmark, emitted as runs: a glyph column is
  # `scale` pixels wide, so there is no need to decide anything per pixel.
  defp text_row(width, left, glyph_row, scale, bg) do
    ink = pixel(@ink)

    cells =
      @word
      |> Enum.flat_map(fn char ->
        lit =
          @glyphs
          |> Map.fetch!(char)
          |> Enum.at(glyph_row)
          |> String.to_charlist()
          |> Enum.map(&(&1 == ?#))

        lit ++ [false]
      end)
      |> Enum.drop(-1)

    block = Enum.map(cells, fn lit -> :binary.copy(if(lit, do: ink, else: bg), scale) end)
    right = max(width - left - length(cells) * scale, 0)

    [:binary.copy(bg, left), block, :binary.copy(bg, right)]
  end

  # Big enough to read across the room, small enough to fit with margins.
  defp scale_for(width) do
    max(1, div(width - div(width, 8), length(@word) * (@glyph_w + 1)))
  end

  defp pixel({r, g, b}), do: <<b, g, r, 0>>

  defp await_framebuffer(fb, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(fb, deadline)
  end

  defp do_await(fb, deadline) do
    cond do
      File.exists?(fb) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(100)
        do_await(fb, deadline)
    end
  end

  @doc """
  Unbind fbcon from the framebuffer, so kernel messages stop drawing over us.

  Best-effort by design: every failure here is survivable, and the fallback is
  exactly the behaviour that exists today.
  """
  def quiesce_console(root \\ "/sys/class/vtconsole") do
    root
    |> Path.join("vtcon*")
    |> Path.wildcard()
    |> Enum.filter(&framebuffer_console?/1)
    |> Enum.each(fn dir ->
      case File.write(Path.join(dir, "bind"), "0") do
        :ok -> Logger.info("[splash] unbound #{Path.basename(dir)} from the framebuffer")
        {:error, reason} -> Logger.info("[splash] left #{Path.basename(dir)}: #{inspect(reason)}")
      end
    end)
  end

  # There are two vtcons: the dummy one and the framebuffer one. Unbinding the
  # dummy achieves nothing, so match on the name rather than the number, which
  # is not fixed.
  defp framebuffer_console?(dir) do
    case File.read(Path.join(dir, "name")) do
      {:ok, name} -> String.contains?(name, "frame buffer")
      _ -> false
    end
  end
end
