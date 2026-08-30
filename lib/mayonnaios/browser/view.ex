defmodule MayonnaiOS.Browser.View do
  @moduledoc """
  What the panel says *about* an entry: the preview pane on the browser's
  right, and the one-wide-column full view that X opens.

  Pure functions from a column entry to a description the scene can draw.
  `MayonnaiOS.Browser` calls them -- the preview on every repaint, the full
  view once when X opens it -- and holds what they return; the scene renders
  the result and owns nothing, the same division the rest of the browser
  lives by. Directories and the other expandable nodes are previewed by the
  browser itself, as the column a descend would open, so this module only
  describes leaves: files, programs, and the launcher's own verbs.

  ## What a file looks like from here

  The first bytes decide. A head that a decoder recognises as an image is an
  image; a head that is UTF-8 with no null bytes is text; everything else is
  bytes, shown as a hexdump -- which is not a fallback so much as the honest
  answer for a save file or a ROM.

  Every read is capped. The classifying peek is 64 KB, which is enough for a
  JPEG that buries its dimensions behind EXIF blocks; the text view loads a
  quarter megabyte; the image view refuses anything past 8 MB, because the
  decode happens in the display driver on this SoC's CPU. A cap that is hit
  goes on the panel as "the first N of M" rather than being passed off as
  the whole file.

  ## The process monitors are entries with a pulse

  A row that opens `MayonnaiOS.Top` is previewed as a narrow slice of the
  readout itself: the top of the list by memory, sampled when the preview is
  built. One sample, no deltas -- the activity column needs a previous
  sample and a preview has none, so memory is the honest column to show.
  """

  alias MayonnaiOS.{Browser, Files, Pickles, Top}

  @typedoc """
  A preview pane: what the browser's right column shows for a leaf.
  """
  @type preview ::
          %{kind: :file, title: String.t(), info: [String.t()], body: body()}
          | %{kind: :info, title: String.t(), lines: [String.t()]}
          | %{kind: :top, title: String.t(), lines: [String.t()]}

  @typedoc "The contents half of a file preview."
  @type body ::
          nil
          | {:text, [String.t()]}
          | {:hex, [String.t()]}
          | {:image, image()}
          | {:note, String.t()}

  @typedoc """
  A decoded-enough image: dimensions and format from the header, and the
  bytes when the file is small enough to hand to the display driver.
  """
  @type image :: %{
          format: String.t(),
          width: pos_integer(),
          height: pos_integer(),
          bytes: binary() | nil
        }

  @typedoc "A full view: one wide column, scrolled by the browser."
  @type full ::
          %{kind: :listing, title: String.t(), lines: [String.t()], note: String.t() | nil}
          | %{kind: :text, title: String.t(), lines: [String.t()], note: String.t() | nil}
          | %{kind: :hex, title: String.t(), lines: [String.t()], note: String.t() | nil}
          | %{kind: :image, title: String.t(), image: image(), note: String.t() | nil}
          | %{kind: :info, title: String.t(), lines: [String.t()]}

  # One read for a preview: enough to classify honestly, enough text to fill
  # the pane many times over, and bounded whatever the file's size is.
  @peek 65_536

  # The most a text view loads. A quarter megabyte is hundreds of screens of
  # config file; anything bigger is being read for its head anyway.
  @text_cap 262_144

  # The most a hex view loads: 4 KB is 256 dump lines, and the point of a
  # hexdump on this panel is the header of the thing, not all of it.
  @hex_cap 4_096

  # The most an image view hands to the display driver, whose decoder runs on
  # the CPU that also runs everything else. Bigger files keep their metadata
  # and lose only the picture.
  @image_cap 8 * 1024 * 1024

  # How many entries the preview of anything list-shaped shows, and how many
  # lines of a file's contents. Sized to the pane, not to the data.
  @preview_body 8

  # -- the preview pane ---------------------------------------------------------

  @doc """
  The preview for a leaf entry, or `nil` for one with nothing to say.

  `column` is the location of the column the entry sits in -- how a file's
  bytes are reached -- and is `nil` outside the file tree.
  """
  @spec preview(Browser.node_(), Files.location() | nil) :: preview() | nil
  def preview(%{kind: :file, name: name, entry: entry}, column) do
    %{kind: :file, title: name, info: file_info(entry), body: preview_body(column, name, entry)}
  end

  def preview(%{kind: :program, name: name, program: %{app: {Top, which}}}, _column) do
    %{kind: :top, title: name, lines: top_lines(which)}
  end

  def preview(%{kind: :program, name: name, program: program}, _column) do
    %{kind: :info, title: name, lines: program_lines(program)}
  end

  def preview(%{kind: :system, name: name, core: {:ok, core}}, _column) do
    %{kind: :info, title: name, lines: ["A opens the ROM library", "Core: #{core.label}"]}
  end

  def preview(%{kind: :system, name: name}, _column) do
    %{kind: :info, title: name, lines: ["No installed core", "Install one from the web page"]}
  end

  def preview(%{kind: :rom, name: name, entry: entry}, _column) do
    %{kind: :info, title: name, lines: ["A launches this ROM", bytes(entry.size)]}
  end

  def preview(_node, _column), do: nil

  # What the entry *is*, before what it contains: its links, its size, its
  # type. These are the lines above the contents in the preview pane.
  defp file_info(%{broken?: true, link: link}), do: ["a broken link to #{link || "?"}"]

  defp file_info(%{link: link} = entry) when is_binary(link) do
    ["a link to #{link}" | file_info(%{entry | link: nil})]
  end

  defp file_info(%{type: :regular, size: size}) when is_integer(size) and size >= 1024 do
    ["a file of #{bytes(size)} (#{size} bytes)"]
  end

  defp file_info(%{type: :regular, size: size}), do: ["a file of #{size} bytes"]
  defp file_info(%{type: type}), do: ["a #{type}"]

  defp preview_body(nil, _name, _entry), do: nil

  defp preview_body(column, name, %{type: :regular}) do
    with {:ok, target} <- Files.descend(column, name),
         {:ok, head} <- Files.peek(target, @peek) do
      cond do
        head == <<>> ->
          {:note, "empty"}

        image = image_meta(head) ->
          {:image, load_image(target, image)}

        text?(head) ->
          {:text, head |> text_lines() |> Enum.take(@preview_body)}

        true ->
          {:hex, head |> take_bytes(8 * @preview_body) |> narrow_hex()}
      end
    else
      {:error, reason} -> {:note, "cannot be read: #{Browser.why(reason)}"}
    end
  end

  # A device node, a socket, a directory that lost its location: nothing to
  # read, and the info lines above have already said what it is.
  defp preview_body(_column, _name, _entry), do: nil

  # -- the full view ------------------------------------------------------------

  @doc """
  The full view X opens for an entry: one wide column, described whole.

  `nil` for an entry with nothing more to show than its row -- the root
  categories. The process monitors never reach here from a button: the
  launcher opens the `MayonnaiOS.Top` app itself, because the app *is* their
  detailed view.
  """
  @spec full(Browser.node_(), Files.location() | nil) :: full() | nil
  def full(%{kind: :dir, name: name, location: location}, _column), do: listing(name, location)

  def full(%{kind: :place, name: name, key: key}, _column) do
    case Files.at(key) do
      {:ok, location} -> listing(name, location)
      {:error, reason} -> info(name, ["cannot be opened: #{Browser.why(reason)}"])
    end
  end

  def full(%{kind: :file, name: name, entry: entry}, column) do
    file_full(name, entry, column)
  end

  def full(%{kind: :program, name: name, program: program}, _column) do
    info(name, program_lines(program))
  end

  def full(_node, _column), do: nil

  # The detailed listing: every entry with its size, one line each, in the
  # order `Files.list/1` already sorts them.
  defp listing(name, location) do
    case Files.list(location) do
      {:ok, entries} ->
        %{
          kind: :listing,
          title: name,
          lines: Enum.map(entries, &listing_line/1),
          note: if(entries == [], do: "Empty.")
        }

      {:error, reason} ->
        info(name, ["cannot be read: #{Browser.why(reason)}"])
    end
  end

  defp listing_line(entry) do
    String.pad_trailing(shorten(entry.name, 40), 42) <>
      String.pad_leading(entry_size(entry), 10) <>
      link_words(entry)
  end

  defp entry_size(%{broken?: true}), do: "broken"
  defp entry_size(%{type: :directory}), do: "directory"
  defp entry_size(%{type: :regular, size: size}), do: bytes(size)
  defp entry_size(%{type: type}), do: to_string(type)

  defp link_words(%{link: nil}), do: ""
  defp link_words(%{link: target}), do: "  -> " <> shorten_left(target, 24)

  defp file_full(name, %{type: :regular} = entry, column) when column != nil do
    with {:ok, target} <- Files.descend(column, name),
         {:ok, head} <- Files.peek(target, @peek) do
      cond do
        head == <<>> -> info(name, file_info(entry) ++ ["empty"])
        image = image_meta(head) -> image_full(name, target, image, entry)
        text?(head) -> text_full(name, target, entry)
        true -> hex_full(name, target, entry)
      end
    else
      {:error, reason} -> unreadable(name, entry, reason)
    end
  end

  defp file_full(name, entry, _column), do: info(name, file_info(entry))

  defp text_full(name, target, entry) do
    case Files.peek(target, @text_cap) do
      {:ok, data} ->
        %{kind: :text, title: name, lines: text_lines(data), note: cap_note(entry, data)}

      {:error, reason} ->
        unreadable(name, entry, reason)
    end
  end

  defp hex_full(name, target, entry) do
    case Files.peek(target, @hex_cap) do
      {:ok, data} ->
        %{kind: :hex, title: name, lines: hexdump(data), note: cap_note(entry, data)}

      {:error, reason} ->
        unreadable(name, entry, reason)
    end
  end

  defp image_full(name, target, meta, entry) do
    image = load_image(target, meta)

    %{
      kind: :image,
      title: name,
      image: image,
      note: if(image.bytes == nil, do: "too big to decode (#{bytes(entry.size)})")
    }
  end

  defp unreadable(name, entry, reason) do
    info(name, file_info(entry) ++ ["cannot be read: #{Browser.why(reason)}"])
  end

  defp info(title, lines), do: %{kind: :info, title: title, lines: lines}

  # Said on the panel when the cap was hit: "the first 256.0K of 1.2G" is a
  # different claim from silently showing a head as though it were the whole.
  defp cap_note(%{size: size}, data) when is_integer(size) and size > byte_size(data) do
    "the first #{bytes(byte_size(data))} of #{bytes(size)}"
  end

  defp cap_note(_entry, _data), do: nil

  # -- classifying --------------------------------------------------------------

  # The header parse the display driver's decoder also agrees with:
  # ExImageInfo is what `Scenic.Assets.Stream.Image.from_binary/1` uses, so a
  # file called an image here is one the stream will accept.
  defp image_meta(head) do
    case ExImageInfo.info(head) do
      {format, width, height, _variant} -> %{format: format, width: width, height: height}
      nil -> nil
    end
  end

  # The whole file, when it is small enough to hand to the decoder. Past the
  # cap the dimensions still get shown -- they came off the header -- and
  # only the picture is declined.
  defp load_image(target, meta) do
    case Files.peek(target, @image_cap + 1) do
      {:ok, data} when byte_size(data) <= @image_cap -> Map.put(meta, :bytes, data)
      _too_big_or_unreadable -> Map.put(meta, :bytes, nil)
    end
  end

  defp text?(head) do
    not String.contains?(head, <<0>>) and utf8?(head, 3)
  end

  # The peek can cut a multi-byte character at its boundary, so up to three
  # trailing bytes are allowed to be the front of one before the head stops
  # counting as text.
  defp utf8?(head, 0), do: String.valid?(head)

  defp utf8?(head, spare) do
    String.valid?(head) or
      (byte_size(head) > 0 and utf8?(binary_part(head, 0, byte_size(head) - 1), spare - 1))
  end

  defp text_lines(data) do
    data
    |> String.replace("\r", "")
    |> String.replace("\t", "  ")
    |> String.split("\n")
  end

  # -- hex ------------------------------------------------------------------------

  @doc """
  Classic hexdump lines: offset, sixteen bytes, the printable characters.

  Public because the format is a contract with the panel's monospace column
  -- 75 characters, which is what fits -- and a test should be able to pin
  it without building a file tree.
  """
  @spec hexdump(binary()) :: [String.t()]
  def hexdump(data) do
    data
    |> chunks(16)
    |> Enum.with_index()
    |> Enum.map(fn {chunk, index} ->
      hex_offset(index * 16) <>
        "  " <> String.pad_trailing(hex_pairs(chunk), 47) <> "  |#{ascii(chunk)}|"
    end)
  end

  # The preview pane's narrow cousin: eight bytes a line, no offset and no
  # ascii, because the pane is a third of the panel wide.
  defp narrow_hex(data) do
    for chunk <- chunks(data, 8), do: hex_pairs(chunk)
  end

  defp hex_offset(offset) do
    offset |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(6, "0")
  end

  defp hex_pairs(chunk) do
    chunk
    |> :binary.bin_to_list()
    |> Enum.map_join(" ", fn byte ->
      byte |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")
    end)
  end

  defp ascii(chunk) do
    for <<byte <- chunk>>, into: "", do: if(byte in 32..126, do: <<byte>>, else: ".")
  end

  defp chunks(<<>>, _size), do: []
  defp chunks(data, size) when byte_size(data) <= size, do: [data]

  defp chunks(data, size) do
    <<head::binary-size(^size), rest::binary>> = data
    [head | chunks(rest, size)]
  end

  defp take_bytes(data, count), do: binary_part(data, 0, min(byte_size(data), count))

  # -- the runnable rows -----------------------------------------------------------

  # What a program row is and what the buttons do to it. The words name the
  # launcher's own bindings, so they live next to the other button prose and
  # change when it does.
  defp program_lines(%{action: :poweroff}) do
    [
      "A verb of the launcher's own.",
      "A shows the splash, then switches off."
    ]
  end

  defp program_lines(%{action: action}) when action != nil do
    ["A verb of the launcher's own.", "A runs it."]
  end

  defp program_lines(%{app: {Pickles.App, _name}}) do
    ["A pickle: a sandboxed Lua app.", "A opens it. Menu leaves it."]
  end

  defp program_lines(%{app: app}) when app != nil do
    ["An app in this firmware.", "A opens it. Menu leaves it."]
  end

  defp program_lines(%{installed?: false} = program) do
    ["A program.", program.path || "", "Not installed: nothing is at that path."]
  end

  defp program_lines(program) do
    ["A program on this device.", program.path || ""] ++
      args_lines(program) ++ ["A runs it. Menu stops it."]
  end

  defp args_lines(%{args: []}), do: []
  defp args_lines(%{args: args}), do: ["args: " <> Enum.join(args, " ")]

  # The narrow process list: the top of the readout by memory, one sample.
  defp top_lines(:beam) do
    Top.Beam.sample() |> Top.Beam.rows(nil) |> top_rows()
  end

  defp top_lines(:os) do
    case Top.Os.sample() do
      {:ok, sample} -> sample |> Top.Os.rows(nil) |> top_rows()
      {:error, reason} -> ["no reading: #{inspect(reason)}"]
    end
  end

  defp top_rows(rows) do
    rows
    |> Enum.sort_by(& &1.mem, :desc)
    |> Enum.take(@preview_body)
    |> Enum.map(fn row ->
      String.pad_leading(bytes(row.mem), 6) <> "  " <> shorten(row_name(row), 18)
    end)
  end

  defp row_name(%{name: name}) when is_binary(name), do: name
  defp row_name(%{name: name}), do: inspect(name)

  # -- words -----------------------------------------------------------------------

  defp bytes(nil), do: "--"
  defp bytes(b) when b < 1024, do: "#{b} B"

  defp bytes(b) do
    {value, unit} =
      cond do
        b >= 1024 * 1024 * 1024 -> {b / (1024 * 1024 * 1024), "G"}
        b >= 1024 * 1024 -> {b / (1024 * 1024), "M"}
        true -> {b / 1024, "K"}
      end

    "#{:erlang.float_to_binary(value, decimals: 1)}#{unit}"
  end

  defp shorten(words, max) do
    if String.length(words) <= max, do: words, else: String.slice(words, 0, max - 1) <> "…"
  end

  defp shorten_left(words, max) do
    if String.length(words) <= max do
      words
    else
      "…" <> String.slice(words, String.length(words) - max + 1, max)
    end
  end
end
