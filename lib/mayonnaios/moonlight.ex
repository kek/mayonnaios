defmodule MayonnaiOS.Moonlight do
  @moduledoc """
  The player's own `moonlight.conf`: what is in it, and how to change it
  without losing what this firmware did not put there.

  Moonlight Embedded reads one config file, named on its command line by
  `MayonnaiOS.Programs`' row for it, and everything a player would want to
  change about a stream is a line in that file. Until this module existed the
  only way to write those lines was an SSH session -- see the README's Game
  streaming section -- which is a poor arrangement for the two settings most
  likely to need changing, because both are things you discover from the
  couch: the host moved, or 720p30 stutters and the bitrate has to come down.

  ## The file is edited, not generated

  `render/2` replaces the value of the keys this screen owns *in place* and
  copies every other line through untouched -- comments, blank lines, and any
  key a player set over SSH that no row here offers (`surround`, `rotate`,
  `viewonly`, `packetsize`). A settings screen that rewrote the file from its
  own idea of what belongs in it would silently delete those, and the failure
  would show up as "the stream stopped rotating" days later with nothing
  connecting it to a visit to this screen.

  Keys the screen owns but the file does not have yet are appended; a key
  whose value is cleared has its line removed rather than written empty,
  because `address = ` parses as an address of the empty string, not as an
  absent address.

  ## Where the first version of the file comes from

  Opening the screen on a device that has never streamed shows the bundle's
  own template -- `share/moonlight/moonlight.conf`, which carries the
  hardware-dictated defaults and the comments explaining them -- rather than
  an empty page. Saving then writes that template plus the player's changes
  to `/root/.config/moonlight/moonlight.conf`, which is exactly the `cp` the
  README's SSH session does, done by pressing A.

  With no bundle installed there is no template either, so `@base` below is
  a minimal stand-in with the same defaults in it. That path is reachable:
  the Moonlight row is visible before the bundle is, and so is this one.

  ## Resolution is two keys and one row

  `width` and `height` are separate keys in the file and one choice on the
  screen, because they are one decision. A file that names a size this screen
  does not offer keeps it -- `choices/2` puts the current value in the list
  rather than snapping it to the nearest known one, so a hand-tuned 1600x900
  survives being looked at.

  ## What this module cannot tell you

  Whether the device is paired with the host. Pairing is a challenge exchange
  that leaves its result in the host's own list of clients; the only thing on
  this side is a client certificate in `~/.cache/moonlight`, and that file is
  written on first run whether or not any host ever accepted it. So the screen
  does not claim to know, and pairing stays the one-time SSH step the README
  describes.
  """

  alias MayonnaiOS.Bundle

  @bundle "moonlight"

  @default_config_path "/root/.config/moonlight/moonlight.conf"

  @type field :: %{
          id: atom(),
          label: String.t(),
          kind: :text | :choice,
          choices: [String.t()],
          suffix: String.t(),
          placeholder: String.t(),
          note: String.t()
        }

  @type settings :: %{atom() => String.t()}

  @type source :: :file | :template | :defaults

  # The rows, in the order they are drawn. `keys` is how a row becomes lines
  # in the file, and it is a list because resolution is two of them.
  #
  # The choices are what this hardware can actually be asked for rather than
  # everything Moonlight accepts: the stream is decoded in software on four
  # A53s and the panel is 640x480, so 1080p is on the list as the thing a
  # Sunshine host will happily send and this device will drop frames on, and
  # 4K is not on it at all.
  @fields [
    %{
      id: :address,
      label: "Host address",
      kind: :text,
      keys: ["address"],
      choices: [],
      suffix: "",
      placeholder: "not set",
      note: "The Sunshine or GeForce host. An IP address or a name."
    },
    %{
      id: :resolution,
      label: "Resolution",
      kind: :choice,
      keys: ["width", "height"],
      choices: ["640x480", "1280x720", "1920x1080"],
      suffix: "",
      placeholder: "",
      note: "The panel is 640x480; anything larger is scaled down to it."
    },
    %{
      id: :fps,
      label: "Frame rate",
      kind: :choice,
      keys: ["fps"],
      choices: ["30", "60"],
      suffix: " fps",
      placeholder: "",
      note: "30 is the honest starting point for a software decoder."
    },
    %{
      id: :bitrate,
      label: "Bitrate",
      kind: :choice,
      keys: ["bitrate"],
      choices: ["2000", "5000", "10000", "20000"],
      suffix: " kbps",
      placeholder: "",
      note: "Lower this first if the picture stutters: bitrate costs decode."
    },
    %{
      id: :codec,
      label: "Codec",
      kind: :choice,
      keys: ["codec"],
      choices: ["h264", "hevc", "auto"],
      suffix: "",
      placeholder: "",
      note: "HEVC halves the bitrate and roughly doubles the decode cost."
    },
    %{
      id: :app,
      label: "App",
      kind: :text,
      keys: ["app"],
      choices: [],
      suffix: "",
      placeholder: "Steam",
      note: "What to launch on the host. Empty means Moonlight's own default."
    }
  ]

  # The same values the bundle's template carries, so a device with no bundle
  # and no file shows the same starting point as one that has both.
  @defaults %{
    address: "",
    resolution: "1280x720",
    fps: "30",
    bitrate: "5000",
    codec: "h264",
    app: ""
  }

  # The file to edit when there is neither a saved one nor a bundle template.
  # `platform = sdl` is here for the reason the template gives: it is the only
  # platform in this build, and naming it skips the auto-detection walk.
  @base """
  ## Moonlight Embedded on this device.
  ##
  ## Written by the Moonlight settings screen; edit it there or over SSH,
  ## either is fine. Keys this screen does not offer are left alone.

  platform = sdl
  """

  # Appended above any key this screen adds to a file that did not have it,
  # once. Idempotent by inspection of the text rather than by a flag, because
  # the file is also a thing a player edits by hand.
  @marker "## Set from the Moonlight settings screen:"

  # `key = value`, which is what Moonlight's own parser reads. A comment line
  # cannot match: `#` is not in the key class.
  @line ~r/^\s*([A-Za-z0-9_]+)\s*=\s*(.*)$/

  @doc "The rows this screen offers, in the order they are drawn."
  @spec fields() :: [field()]
  def fields, do: @fields

  @doc "The starting values: what the bundle's template asks for."
  @spec defaults() :: settings()
  def defaults, do: @defaults

  @doc """
  The player's config file.

  Configurable so a test can point it at a tmp directory; the default is the
  path `config/target.exs` passes Moonlight on its command line, and the two
  must agree or the screen edits a file nothing reads.
  """
  @spec config_path() :: String.t()
  def config_path do
    Application.get_env(:mayonnaios, :moonlight_config, @default_config_path)
  end

  @doc """
  The bundle's template, or `nil` when the bundle is not installed.
  """
  @spec template_path() :: String.t() | nil
  def template_path do
    case Bundle.current(@bundle) do
      nil -> nil
      dir -> exists(Path.join([dir, "share", "moonlight", "moonlight.conf"]))
    end
  end

  @doc """
  Whether the Moonlight bundle is installed.

  The screen is usable without it -- a config file can be written before the
  program that reads it arrives -- but the panel says so, on the same grounds
  as `MayonnaiOS.Programs`: a row that quietly does nothing looks exactly like
  a row that worked.
  """
  @spec installed?() :: boolean()
  def installed? do
    case Bundle.current(@bundle) do
      nil -> false
      dir -> File.exists?(Path.join([dir, "bin", "moonlight"]))
    end
  end

  @doc """
  The current settings and where they came from.

  `:file` is the player's own config, `:template` the bundle's untouched
  defaults, `:defaults` this module's copy of them. The source is part of the
  answer rather than a detail: "5000 kbps" means something different when it
  is what you chose than when it is what nobody has chosen yet.
  """
  @spec load() :: {settings(), source()}
  def load do
    {text, source} = base_text()
    {parse(text), source}
  end

  @doc """
  Parse a config file into settings, with `defaults/0` for anything absent.
  """
  @spec parse(String.t()) :: settings()
  def parse(text) do
    pairs = pairs_in(text)

    @defaults
    |> put_present(:address, pairs["address"])
    |> put_resolution(pairs["width"], pairs["height"])
    |> put_present(:fps, pairs["fps"])
    |> put_present(:bitrate, pairs["bitrate"])
    |> put_present(:codec, pairs["codec"])
    |> put_present(:app, pairs["app"])
  end

  @doc """
  Apply settings to a config file's text.

  Managed keys are replaced where they already are, cleared ones are removed,
  and the rest are appended. Every other line is copied through: see the
  moduledoc for why that is the whole point of this function.
  """
  @spec render(String.t(), settings()) :: String.t()
  def render(text, settings) do
    wanted = Map.new(config_pairs(settings))
    lines = String.split(text, "\n")

    {kept, seen} =
      Enum.map_reduce(lines, MapSet.new(), fn line, seen ->
        case Regex.run(@line, line) do
          [_, key, _value] ->
            case Map.fetch(wanted, key) do
              :error -> {line, seen}
              {:ok, ""} -> {:drop, MapSet.put(seen, key)}
              {:ok, value} -> {"#{key} = #{value}", MapSet.put(seen, key)}
            end

          _no_match ->
            {line, seen}
        end
      end)

    missing =
      for {key, value} <- config_pairs(settings),
          value != "",
          not MapSet.member?(seen, key),
          do: "#{key} = #{value}"

    kept
    |> Enum.reject(&(&1 == :drop))
    |> append(missing, text)
    |> Enum.join("\n")
  end

  @doc """
  Write settings to `config_path/0`, creating the directory if it is missing.

  Returns the path on success so the panel can say where it went -- a player
  who is about to be told to edit the file by hand needs the name of it.
  """
  @spec save(settings()) :: {:ok, String.t()} | {:error, term()}
  def save(settings) do
    path = config_path()
    {text, _source} = base_text()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, render(text, settings)) do
      {:ok, path}
    end
  end

  @doc """
  The values a choice row can take, with the current one included.

  A file that names a size, rate or codec this screen does not offer is a
  file someone meant that way; the row shows it and steps away from it rather
  than pretending the nearest listed value was what they wrote.
  """
  @spec choices(field(), settings()) :: [String.t()]
  def choices(%{kind: :choice, id: id, choices: choices}, settings) do
    current = Map.get(settings, id, "")
    if current == "" or current in choices, do: choices, else: choices ++ [current]
  end

  def choices(_field, _settings), do: []

  @doc """
  What a row's value reads as on the panel.

  An empty text row reads as its placeholder -- "not set" for the address,
  "Steam" for the app, which is the value Moonlight uses when the key is
  absent. Both are the truth about an empty field, and neither is blank.
  """
  @spec display(field(), settings()) :: String.t()
  def display(%{id: id, suffix: suffix, placeholder: placeholder}, settings) do
    case Map.get(settings, id, "") do
      "" -> placeholder
      value -> value <> suffix
    end
  end

  @doc """
  The next value of a choice row, `+1` or `-1` from the current one, wrapping.
  """
  @spec step(field(), settings(), -1 | 1) :: settings()
  def step(%{kind: :choice, id: id} = field, settings, delta) do
    options = choices(field, settings)
    current = Map.get(settings, id, "")

    case Enum.find_index(options, &(&1 == current)) do
      nil ->
        Map.put(settings, id, hd(options))

      index ->
        Map.put(settings, id, Enum.at(options, Integer.mod(index + delta, length(options))))
    end
  end

  def step(_field, settings, _delta), do: settings

  @doc """
  The config keys and values a set of settings becomes.

  Public because it is the tested surface, and because it is the only place
  that knows one row can be two keys.
  """
  @spec config_pairs(settings()) :: [{String.t(), String.t()}]
  def config_pairs(settings) do
    Enum.flat_map(@fields, fn field -> keys_of(field, Map.get(settings, field.id, "")) end)
  end

  # -- reading -------------------------------------------------------------------

  # The text to edit, and where it came from. The player's file first, the
  # bundle's template second, this module's copy of it last.
  defp base_text do
    with nil <- read(config_path(), :file),
         nil <- read(template_path(), :template) do
      {@base, :defaults}
    end
  end

  defp read(nil, _source), do: nil

  defp read(path, source) do
    case File.read(path) do
      {:ok, text} -> {text, source}
      {:error, _reason} -> nil
    end
  end

  defp pairs_in(text) do
    text
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case Regex.run(@line, line) do
        [_, key, value] -> Map.put(acc, key, String.trim(value))
        _no_match -> acc
      end
    end)
  end

  defp put_present(settings, _id, nil), do: settings
  defp put_present(settings, _id, ""), do: settings
  defp put_present(settings, id, value), do: Map.put(settings, id, value)

  # Both halves or neither: a file with a width and no height is not naming a
  # resolution, and guessing the other half from the default would produce a
  # size the player never asked for.
  defp put_resolution(settings, width, height)
       when is_binary(width) and is_binary(height) and width != "" and height != "" do
    Map.put(settings, :resolution, "#{width}x#{height}")
  end

  defp put_resolution(settings, _width, _height), do: settings

  # -- writing -------------------------------------------------------------------

  defp keys_of(%{id: :resolution}, value) do
    case String.split(value, "x") do
      [width, height] -> [{"width", width}, {"height", height}]
      _not_a_size -> [{"width", ""}, {"height", ""}]
    end
  end

  defp keys_of(%{keys: [key]}, value), do: [{key, value}]

  defp append(lines, [], _text), do: lines

  defp append(lines, missing, text) do
    # A file that already ends in a newline splits to a trailing empty string;
    # dropping it keeps the appended block flush against the last line rather
    # than one blank line further down on every save.
    kept = trim_trailing_blank(lines)

    header =
      cond do
        String.contains?(text, @marker) -> []
        # Nothing above to separate from: a file whose every line was a key
        # this screen cleared, or one that had no lines at all.
        kept == [] -> [@marker]
        true -> ["", @marker]
      end

    kept ++ header ++ missing ++ [""]
  end

  defp trim_trailing_blank(lines) do
    lines |> Enum.reverse() |> Enum.drop_while(&(&1 == "")) |> Enum.reverse()
  end

  defp exists(path), do: if(File.exists?(path), do: path)
end
