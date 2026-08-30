defmodule MayonnaiOS.Game do
  @moduledoc "Joins ROM-library entries to an installed RetroArch core and program."

  alias MayonnaiOS.{Cores, Library, Programs}

  @spec core_for(String.t()) :: {:ok, map()} | {:error, :no_core}
  def core_for(system) do
    available = Map.new(Cores.list(), &{&1.key, &1})

    core =
      :mayonnaios
      |> Application.get_env(:core_priority, Cores.catalogue() |> Map.keys() |> Enum.sort())
      |> Enum.find_value(fn key ->
        case available[to_string(key)] do
          %{available: true, systems: systems} = core -> if system in systems, do: core
          _ -> nil
        end
      end)

    case core do
      nil -> {:error, :no_core}
      core -> {:ok, Map.put(core, :path, Path.join(Cores.dir(), "#{core.name}_libretro.so"))}
    end
  end

  @spec system_for(String.t()) :: map() | nil
  def system_for(name) do
    extension = name |> Path.extname() |> String.downcase()
    Enum.find(Library.systems(), &(extension in &1.extensions))
  end

  @spec program(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def program(system, rom_path) do
    with {:ok, core} <- core_for(system),
         %{} = retroarch <- retroarch() do
      {:ok,
       %{
         retroarch
         | name: Path.basename(rom_path),
           args: retroarch.args ++ ["-L", core.path, rom_path]
       }}
    else
      nil -> {:error, :no_retroarch}
      error -> error
    end
  end

  defp retroarch do
    Enum.find(Programs.list(), fn program ->
      program.name == "RetroArch" or
        (is_binary(program.path) and Path.basename(program.path) == "retroarch")
    end)
  end
end
