defmodule MayonnaiOS.DocsManifestTest do
  # The manifest in mix.exs filters out listed pages whose source does not
  # exist, so a typo there is harmless. The opposite mistake is silent: a page
  # committed to docs/ but never listed is simply never published, and nothing
  # in the build says so. These two tests are that missing signal.
  use ExUnit.Case, async: true

  setup_all do
    docs = Mix.Project.config()[:docs].()
    extras = Enum.map(docs[:extras], fn {path, _options} -> path end)
    grouped = docs[:groups_for_extras] |> Enum.flat_map(fn {_group, paths} -> paths end)

    %{extras: extras, grouped: grouped}
  end

  test "every page in docs/ is listed in extras", %{extras: extras} do
    assert Path.wildcard("docs/*.md") -- extras == []
  end

  test "every published page belongs to a sidebar group", %{extras: extras, grouped: grouped} do
    assert extras -- grouped == []
  end
end
