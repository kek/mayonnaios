defmodule MayonnaiOS.Browser.ViewTest do
  use ExUnit.Case, async: false

  alias MayonnaiOS.Browser.View
  alias MayonnaiOS.Files

  # These run against a real temporary directory for the reason the browser
  # tests do: what is being asserted is what a set of bytes on a disk looks
  # like from the panel, and a mock would only agree with itself.

  # A complete 1x1 PNG, byte for byte: signature, IHDR, one IDAT, IEND. Small
  # enough to write out and real enough that the same parser the display
  # driver trusts recognises it.
  @png <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, ?I, ?H, ?D, ?R, 0, 0, 0,
         1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 0x1F, 0x15, 0xC4, 0x89, 0, 0, 0, 0x0D, ?I, ?D, ?A, ?T,
         0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0, 0,
         0, 0, ?I, ?E, ?N, ?D, 0xAE, 0x42, 0x60, 0x82>>

  setup do
    root = Path.join(System.tmp_dir!(), "view-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "sub"))
    File.write!(Path.join(root, "notes.txt"), "one\ttab\r\ntwo\nthree\nfour")
    File.write!(Path.join(root, "save.bin"), <<0, 1, 2, 254, 255, ?H, ?I>>)
    File.write!(Path.join(root, "pixel.png"), @png)
    File.write!(Path.join(root, "empty"), "")
    File.write!(Path.join(root, "sub/rom.sfc"), "123456789")

    Application.put_env(:mayonnaios, :file_roots, [%{key: "r", path: root, note: ""}])

    on_exit(fn ->
      File.rm_rf(root)
      Application.delete_env(:mayonnaios, :file_roots)
    end)

    {:ok, column} = Files.at("r")
    %{root: root, column: column}
  end

  defp file_node(column, name) do
    {:ok, location} = Files.descend(column, name)
    {:ok, entry} = Files.stat(location)
    %{kind: :file, name: name, entry: entry}
  end

  describe "Files.peek/2" do
    test "reads at most the asked-for bytes", %{column: column} do
      {:ok, location} = Files.descend(column, "notes.txt")

      assert {:ok, "one"} = Files.peek(location, 3)
      assert {:ok, "one\ttab\r\ntwo\nthree\nfour"} = Files.peek(location, 1_000_000)
    end

    test "an empty file is empty, not an error", %{column: column} do
      {:ok, location} = Files.descend(column, "empty")
      assert {:ok, <<>>} = Files.peek(location, 16)
    end

    test "a missing file says why", %{column: column} do
      {:ok, location} = Files.descend(column, "not-there")
      assert {:error, :enoent} = Files.peek(location, 16)
    end
  end

  describe "previewing a file" do
    test "a text file previews its first lines", %{column: column} do
      preview = View.preview(file_node(column, "notes.txt"), column)

      assert %{kind: :file, title: "notes.txt", info: [info], body: {:text, lines}} = preview
      assert info =~ "a file of"
      # Tabs become spaces and carriage returns go, so the panel never draws
      # a control character.
      assert ["one  tab", "two", "three", "four"] = lines
    end

    test "bytes that are not text preview as a narrow hexdump", %{column: column} do
      preview = View.preview(file_node(column, "save.bin"), column)

      assert %{body: {:hex, [line]}} = preview
      assert line == "00 01 02 fe ff 48 49"
    end

    test "an image previews as its pixels and its header facts", %{column: column} do
      preview = View.preview(file_node(column, "pixel.png"), column)

      assert %{body: {:image, image}} = preview
      assert %{format: "image/png", width: 1, height: 1, bytes: @png} = image
    end

    test "an empty file says so", %{column: column} do
      assert %{body: {:note, "empty"}} = View.preview(file_node(column, "empty"), column)
    end

    test "a file with no column location keeps its info and loses the read" do
      node = %{
        kind: :file,
        name: "x",
        entry: %{type: :regular, size: 3, link: nil, broken?: false}
      }

      assert %{info: _lines, body: nil} = View.preview(node, nil)
    end
  end

  describe "previewing a runnable row" do
    test "a program shows its path and that A runs it" do
      [program] = MayonnaiOS.Programs.list([%{path: System.find_executable("sh")}])
      preview = View.preview(%{kind: :program, name: "sh", program: program}, nil)

      assert %{kind: :info, lines: lines} = preview
      assert Enum.any?(lines, &(&1 =~ "A runs it"))
      assert program.path in lines
    end

    test "a missing program says not installed" do
      [program] = MayonnaiOS.Programs.list([%{path: "/nonexistent/prog"}])
      preview = View.preview(%{kind: :program, name: "prog", program: program}, nil)

      assert Enum.any?(preview.lines, &(&1 =~ "Not installed"))
    end

    test "the power-off verb says A acts immediately" do
      [program] = MayonnaiOS.Programs.list([%{name: "Power off", action: :poweroff}])
      preview = View.preview(%{kind: :program, name: "Power off", program: program}, nil)

      assert Enum.any?(preview.lines, &(&1 =~ "A shows the splash"))
    end

    test "a process monitor previews as a narrow list by memory" do
      [program] = MayonnaiOS.Programs.list([%{name: "BEAM", app: {MayonnaiOS.Top, :beam}}])
      preview = View.preview(%{kind: :program, name: "BEAM", program: program}, nil)

      assert %{kind: :top, lines: [_ | _] = lines} = preview
      # Widest first: the list is the readout's head, by memory.
      mems = for line <- lines, do: line |> String.split() |> hd()
      assert length(mems) <= 10
    end
  end

  describe "the full view" do
    test "a directory is a detailed listing with sizes", %{column: column} do
      {:ok, location} = Files.descend(column, "sub")
      node = %{kind: :dir, name: "sub", location: location, entry: %{type: :directory}}

      assert %{kind: :listing, title: "sub", lines: [line], note: nil} =
               View.full(node, column)

      assert line =~ "rom.sfc"
      assert line =~ "9 B"
    end

    test "an empty directory says Empty", %{root: root, column: column} do
      File.mkdir_p!(Path.join(root, "hollow"))
      {:ok, location} = Files.descend(column, "hollow")
      node = %{kind: :dir, name: "hollow", location: location, entry: %{type: :directory}}

      assert %{kind: :listing, lines: [], note: "Empty."} = View.full(node, column)
    end

    test "a place opens as a listing of its root" do
      node = %{kind: :place, name: "r", key: "r", note: ""}

      assert %{kind: :listing, lines: lines} = View.full(node, nil)
      assert Enum.any?(lines, &(&1 =~ "notes.txt"))
    end

    test "a text file is a text viewer", %{column: column} do
      assert %{kind: :text, lines: lines, note: nil} =
               View.full(file_node(column, "notes.txt"), column)

      assert "three" in lines
    end

    test "other bytes are a hexdump with offsets and printables", %{column: column} do
      assert %{kind: :hex, lines: [line]} = View.full(file_node(column, "save.bin"), column)
      assert line == "000000  00 01 02 fe ff 48 49                             |.....HI|"
    end

    test "an image carries its bytes for the panel to draw", %{column: column} do
      assert %{kind: :image, image: %{width: 1, height: 1, bytes: @png}, note: nil} =
               View.full(file_node(column, "pixel.png"), column)
    end

    test "a runnable row is its metadata" do
      [program] = MayonnaiOS.Programs.list([%{path: "/nonexistent/prog"}])
      node = %{kind: :program, name: "prog", program: program}

      assert %{kind: :info, lines: lines} = View.full(node, nil)
      assert Enum.any?(lines, &(&1 =~ "Not installed"))
    end

    test "a category has no full view" do
      assert View.full(%{kind: :category, id: :games, name: "Games"}, nil) == nil
    end
  end

  describe "hexdump/1" do
    test "sixteen bytes a line, offset first, printables last" do
      lines = View.hexdump(:binary.copy(<<0>>, 16) <> "ABCDEFGH")

      assert [
               "000000  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|",
               "000010  41 42 43 44 45 46 47 48                          |ABCDEFGH|"
             ] = lines
    end

    test "nothing dumps to nothing" do
      assert View.hexdump(<<>>) == []
    end
  end
end
