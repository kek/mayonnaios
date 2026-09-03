defmodule Mix.Tasks.Docs.Check do
  use Mix.Task

  @moduledoc false
  @shortdoc "Validates links and assets in generated documentation"

  @pages_prefix "/mayonnaios"
  @html_attribute ~r/(?:\A|\s)(href|src|srcset|id|name)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i
  @html_tag ~r/<[A-Za-z][^>"']*(?:(?:"[^"]*"|'[^']*')[^>"']*)*>/s
  @css_url ~r/url\(\s*(?:"([^"]*)"|'([^']*)'|([^)'"\s][^)]*?))\s*\)/i

  @impl Mix.Task
  def run(args) do
    root = output_directory(args)

    unless File.dir?(root) do
      Mix.raise("documentation output directory does not exist: #{root}")
    end

    root = Path.expand(root)
    files = generated_files(root)
    anchors = Map.new(Enum.filter(files, &(Path.extname(&1) == ".html")), &{&1, anchors(&1)})

    {errors, reference_count} =
      Enum.reduce(files, {[], 0}, fn source, result ->
        validate_file(source, root, anchors, result)
      end)

    if errors != [] do
      details = errors |> Enum.reverse() |> Enum.map_join("\n", &"  * #{&1}")

      Mix.raise(
        "generated documentation has #{length(errors)} invalid local reference(s):\n#{details}"
      )
    end

    Mix.shell().info(
      "Checked #{length(files)} generated HTML/CSS files and #{reference_count} local references."
    )
  end

  defp output_directory([]), do: "doc"
  defp output_directory([directory]), do: directory
  defp output_directory(_), do: Mix.raise("usage: mix docs.check [OUTPUT_DIRECTORY]")

  defp generated_files(root) do
    root
    |> File.ls!()
    |> Enum.flat_map(&walk(Path.join(root, &1)))
    |> Enum.filter(&(Path.extname(&1) in [".html", ".css"]))
    |> Enum.sort()
  end

  defp walk(path) do
    if File.dir?(path) do
      path |> File.ls!() |> Enum.flat_map(&walk(Path.join(path, &1)))
    else
      [path]
    end
  end

  defp validate_file(source, root, anchors, {errors, count}) do
    references(source)
    |> Enum.reduce({errors, count}, fn reference, {current_errors, current_count} ->
      case validate_reference(reference, source, root, anchors) do
        :ignored ->
          {current_errors, current_count}

        :ok ->
          {current_errors, current_count + 1}

        {:error, reason} ->
          source_name = Path.relative_to(source, root)

          {["#{source_name}: #{inspect(reference)} — #{reason}" | current_errors],
           current_count + 1}
      end
    end)
  end

  defp references(path) do
    contents = File.read!(path)

    if Path.extname(path) == ".css" do
      css_references(contents)
    else
      html_references(contents)
    end
  end

  defp html_references(html) do
    html
    |> strip_html_examples()
    |> then(fn markup ->
      Regex.scan(@html_tag, markup)
      |> Enum.flat_map(fn [tag] ->
        Regex.scan(@html_attribute, tag)
        |> Enum.flat_map(fn [_, attribute | values] ->
          value = first_present(values) |> decode_html_entities()

          case String.downcase(attribute) do
            attribute when attribute in ["href", "src"] -> [value]
            "srcset" -> srcset_references(value)
            _ -> []
          end
        end)
      end)
    end)
  end

  defp anchors(path) do
    path
    |> File.read!()
    |> strip_html_examples()
    |> then(&Regex.scan(@html_tag, &1))
    |> Enum.flat_map(fn [tag] ->
      Regex.scan(@html_attribute, tag)
      |> Enum.flat_map(fn [_, attribute | values] ->
        if String.downcase(attribute) in ["id", "name"] do
          [first_present(values) |> decode_html_entities()]
        else
          []
        end
      end)
    end)
    |> MapSet.new()
  end

  # Code examples can contain attribute-shaped text. They are document content,
  # not links for a browser to follow.
  defp strip_html_examples(html) do
    html
    |> String.replace(~r/<!--.*?-->/s, "")
    |> String.replace(~r/<(pre|code)\b[^>]*>.*?<\/\1\s*>/is, "")
  end

  defp css_references(css) do
    css
    |> String.replace(~r/\/\*.*?\*\//s, "")
    |> then(&Regex.scan(@css_url, &1))
    |> Enum.map(fn [_ | values] -> first_present(values) |> String.trim() end)
    |> Enum.reject(&ex_doc_legacy_font_fallback?/1)
  end

  # ExDoc 0.40's bundled Fontsource CSS names legacy Lato `.woff`
  # alternatives that it deliberately does not copy. Modern browsers use the
  # preceding bundled `.woff2` source, so these are not deployable requests.
  defp ex_doc_legacy_font_fallback?(reference) do
    reference
    |> URI.parse()
    |> Map.get(:path, "")
    |> Path.basename()
    |> then(&Regex.match?(~r/^lato-all-(?:400|700)-normal-[A-Z0-9]+\.woff$/, &1))
  end

  defp srcset_references(value) do
    # A srcset candidate's URL is its first whitespace-delimited token. Data
    # URLs may contain a comma, so only commas outside such a token delimit it.
    do_srcset_references(String.trim(value), [])
  end

  defp do_srcset_references("", references), do: Enum.reverse(references)

  defp do_srcset_references(value, references) do
    {url, rest} = take_srcset_url(value)
    rest = rest |> String.trim_leading() |> discard_srcset_descriptor()
    do_srcset_references(trim_srcset_separator(rest), [url | references])
  end

  defp take_srcset_url("data:" <> _ = value) do
    case Regex.run(~r/\A(\S+)(.*)\z/s, value, capture: :all_but_first) do
      [url, rest] -> {url, rest}
      nil -> {value, ""}
    end
  end

  defp take_srcset_url(value) do
    case Regex.run(~r/\A([^\s,]+)(.*)\z/s, value, capture: :all_but_first) do
      [url, rest] -> {url, rest}
      nil -> {value, ""}
    end
  end

  defp discard_srcset_descriptor(rest) do
    case String.split(rest, ",", parts: 2) do
      [_last] -> ""
      [_descriptor, remaining] -> remaining
    end
  end

  defp trim_srcset_separator(value) do
    value |> String.trim_leading() |> String.trim_leading(",") |> String.trim_leading()
  end

  defp validate_reference("", _source, _root, _anchors), do: :ignored

  # ExDoc always emits this optional version-menu hook, but only hosted version
  # sets provide the file. It is not a required site asset.
  defp validate_reference("docs_config.js", _source, _root, _anchors), do: :ignored

  defp validate_reference(reference, source, root, anchors) do
    cond do
      String.starts_with?(reference, "//") ->
        :ignored

      true ->
        uri = URI.parse(reference)

        if uri.scheme do
          :ignored
        else
          validate_local_uri(uri, reference, source, root, anchors)
        end
    end
  rescue
    error in ArgumentError -> {:error, "cannot decode URL: #{Exception.message(error)}"}
  end

  defp validate_local_uri(uri, reference, source, root, anchors) do
    decoded_path = URI.decode(uri.path || "")

    with {:ok, target} <- resolve_path(decoded_path, source, root),
         :ok <- require_file(target),
         :ok <- require_fragment(target, uri.fragment, anchors) do
      :ok
    else
      {:error, reason} -> {:error, "#{reason} (resolved from #{inspect(reference)})"}
    end
  end

  defp resolve_path("", source, _root), do: {:ok, source}

  defp resolve_path(path, source, root) do
    candidate =
      cond do
        path == @pages_prefix or path == @pages_prefix <> "/" ->
          root

        String.starts_with?(path, @pages_prefix <> "/") ->
          Path.join(root, String.trim_leading(path, @pages_prefix <> "/"))

        String.starts_with?(path, "/") ->
          :outside_pages_prefix

        true ->
          Path.expand(path, Path.dirname(source))
      end

    cond do
      candidate == :outside_pages_prefix ->
        {:error, "absolute local path is outside #{@pages_prefix}/"}

      not within?(candidate, root) ->
        {:error, "path escapes the documentation output directory"}

      String.ends_with?(path, "/") or File.dir?(candidate) ->
        {:ok, Path.join(candidate, "index.html")}

      true ->
        {:ok, candidate}
    end
  end

  defp within?(path, root) do
    expanded = Path.expand(path)
    expanded == root or String.starts_with?(expanded, root <> "/")
  end

  defp require_file(path) do
    if File.regular?(path), do: :ok, else: {:error, "local file does not exist: #{path}"}
  end

  defp require_fragment(_target, nil, _anchors), do: :ok
  defp require_fragment(_target, "", _anchors), do: :ok

  defp require_fragment(target, fragment, anchors) do
    if Path.extname(target) == ".html" do
      decoded = URI.decode(fragment)

      if MapSet.member?(Map.get(anchors, target, MapSet.new()), decoded) do
        :ok
      else
        {:error, "fragment ##{decoded} does not exist in #{target}"}
      end
    else
      :ok
    end
  end

  defp first_present(values), do: Enum.find(values, "", &(&1 != ""))

  defp decode_html_entities(value) do
    value
    |> String.replace("&amp;", "&")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
  end
end
