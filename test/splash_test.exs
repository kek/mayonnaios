defmodule MayonnaiOS.SplashTest do
  use ExUnit.Case, async: true

  alias MayonnaiOS.Splash

  @bg <<0xC8, 0xE8, 0xF2, 0>>

  defp pixel(data, w, x, y), do: binary_part(data, (y * w + x) * 4, 4)

  describe "render/2" do
    test "fills the framebuffer exactly" do
      # A short write leaves the tail of the previous contents on screen, so
      # the size is the whole correctness condition for the write itself.
      assert Splash.render(640, 480) |> IO.iodata_to_binary() |> byte_size() == 640 * 480 * 4
    end

    test "works at other geometries, so a different panel is not a crash" do
      for {w, h} <- [{320, 240}, {800, 600}, {1280, 720}] do
        assert Splash.render(w, h) |> IO.iodata_to_binary() |> byte_size() == w * h * 4
      end
    end

    test "the corners are background and the middle is not" do
      w = 640
      h = 480
      d = Splash.render(w, h) |> IO.iodata_to_binary()

      for {x, y} <- [{0, 0}, {w - 1, 0}, {0, h - 1}, {w - 1, h - 1}] do
        assert pixel(d, w, x, y) == @bg, "expected background at #{x},#{y}"
      end

      # Some ink exists somewhere in the band the wordmark occupies.
      band = for y <- 200..280, x <- 0..(w - 1), do: pixel(d, w, x, y)
      assert Enum.any?(band, &(&1 != @bg))
    end

    test "the wordmark is centred" do
      w = 640
      h = 480
      d = Splash.render(w, h) |> IO.iodata_to_binary()

      # Take the row through the middle of the text and find its ink extent.
      row = for x <- 0..(w - 1), do: {x, pixel(d, w, x, div(h, 2))}
      lit = row |> Enum.filter(fn {_, p} -> p != @bg end) |> Enum.map(&elem(&1, 0))

      refute lit == []
      left_margin = Enum.min(lit)
      right_margin = w - 1 - Enum.max(lit)

      # Within one glyph column of symmetric. Not exact, because the wordmark
      # is centred on its cell grid and the outermost columns of M and S are
      # not both ink on every row.
      assert abs(left_margin - right_margin) < 40,
             "margins #{left_margin} and #{right_margin} are not symmetric"
    end

    test "is a whole number of pixels wide on every row" do
      w = 320
      d = Splash.render(w, 240) |> IO.iodata_to_binary()
      assert rem(byte_size(d), w * 4) == 0
    end
  end

  describe "geometry/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "splash-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      %{dir: dir}
    end

    test "reads the panel size from sysfs", %{dir: dir} do
      File.write!(Path.join(dir, "virtual_size"), "800,600\n")
      assert Splash.geometry(dir) == {800, 600}
    end

    test "falls back when sysfs is absent", %{dir: dir} do
      assert Splash.geometry(Path.join(dir, "nope")) == {640, 480}
    end

    test "falls back rather than crashing on nonsense", %{dir: dir} do
      File.write!(Path.join(dir, "virtual_size"), "not,numbers\n")
      assert Splash.geometry(dir) == {640, 480}
    end
  end

  describe "quiesce_console/1" do
    setup do
      root = Path.join(System.tmp_dir!(), "vtcon-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)
      %{root: root}
    end

    defp vtcon(root, name, which) do
      dir = Path.join(root, which)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "name"), name)
      File.write!(Path.join(dir, "bind"), "1")
      dir
    end

    test "unbinds the framebuffer console and leaves the dummy alone", %{root: root} do
      dummy = vtcon(root, "(S) dummy device\n", "vtcon0")
      fb = vtcon(root, "(M) frame buffer device\n", "vtcon1")

      Splash.quiesce_console(root)

      assert File.read!(Path.join(fb, "bind")) == "0"
      assert File.read!(Path.join(dummy, "bind")) == "1"
    end

    test "does nothing when there is no framebuffer console", %{root: root} do
      dummy = vtcon(root, "(S) dummy device\n", "vtcon0")
      Splash.quiesce_console(root)
      assert File.read!(Path.join(dummy, "bind")) == "1"
    end

    test "survives a root that does not exist" do
      assert Splash.quiesce_console("/nonexistent/vtconsole") == :ok
    end
  end

  describe "run/1" do
    test "gives up rather than blocking forever when no framebuffer appears" do
      # The device still boots without a panel: SSH works, games run, and the
      # supervisor must not be held up by a decoration.
      assert :ok =
               Splash.run(
                 fb: "/nonexistent/fb0",
                 sysfs: "/nonexistent",
                 timeout: 150
               )
    end

    test "writes the framebuffer when one is there" do
      dir = Path.join(System.tmp_dir!(), "fb-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      fb = Path.join(dir, "fb0")
      File.write!(fb, "")
      File.write!(Path.join(dir, "virtual_size"), "320,240\n")

      assert :ok = Splash.run(fb: fb, sysfs: dir, timeout: 1_000)
      assert File.stat!(fb).size == 320 * 240 * 4
    end
  end
end
