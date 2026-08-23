defmodule MayonnaiOS.PickleFixtures do
  @moduledoc """
  Builds the pickle tarballs the tests install: a manifest, some Lua, gzipped
  tar via :erl_tar -- the same reader the Store uses, so a fixture that
  builds is a fixture the code under test can open.
  """

  @doc """
  A pickle.json body. `fields` overrides or extends the defaults.
  """
  def manifest(name, fields \\ %{}) do
    %{"name" => name, "version" => "1.0.0"}
    |> Map.merge(fields)
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  @doc """
  A `.tar.gz` under `dir` holding `files`, a list of `{name, contents}`.
  Returns its path.
  """
  def tarball(dir, files) do
    path = Path.join(dir, "pickle-#{System.unique_integer([:positive])}.tar.gz")

    entries =
      Enum.map(files, fn {name, contents} -> {String.to_charlist(name), contents} end)

    :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
    path
  end

  @doc """
  A ready-to-install tarball for a pickle called `name`: manifest plus
  `main.lua` with the given `lua` source. `fields` goes into the manifest.
  """
  def pickle_tarball(dir, name, lua, fields \\ %{}) do
    tarball(dir, [
      {"pickle.json", manifest(name, fields)},
      {"main.lua", lua}
    ])
  end
end
