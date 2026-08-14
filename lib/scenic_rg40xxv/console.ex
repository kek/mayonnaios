defmodule ScenicRg40xxv.Console do
  @moduledoc """
  Hands the panel between the kernel console and the UI.

  This device has `CONFIG_FRAMEBUFFER_CONSOLE=y` and `console=tty0`, which is
  deliberate: UART0 is on internal test pads, so the panel is the only place a
  boot failure is visible. The cost is that fbcon owns the same `/dev/fb0` that
  Scenic draws into, and repaints over it on every kernel message -- WiFi
  associating, USB events, anything. The visible symptom is a scene that
  appears for a few seconds and is then replaced by scrolling kernel log.

  Unbinding fbcon stops that. It is reversible, and worth reversing: with the
  console released, a panic has nowhere to appear.
  """

  require Logger

  @vtconsole "/sys/class/vtconsole"

  @doc """
  Unbind the framebuffer console so the UI owns the panel.
  """
  def release do
    case fbcon() do
      {:ok, path} -> write(path, "0")
      :error -> {:error, :no_fbcon}
    end
  end

  @doc """
  Rebind the framebuffer console, so kernel messages reach the panel again.
  """
  def reclaim do
    case fbcon() do
      {:ok, path} -> write(path, "1")
      :error -> {:error, :no_fbcon}
    end
  end

  @doc """
  True when the framebuffer console currently owns the panel.
  """
  def bound? do
    with {:ok, path} <- fbcon(),
         {:ok, v} <- File.read(path) do
      String.trim(v) == "1"
    else
      _ -> false
    end
  end

  # Find the vtcon whose name says it is the framebuffer device. The index is
  # not stable -- vtcon0 is usually the dummy console -- so match on the name.
  defp fbcon do
    case File.ls(@vtconsole) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.find_value(:error, fn d ->
          case File.read(Path.join([@vtconsole, d, "name"])) do
            {:ok, name} ->
              if name =~ "frame buffer device",
                do: {:ok, Path.join([@vtconsole, d, "bind"])}

            _ ->
              nil
          end
        end)

      _ ->
        :error
    end
  end

  defp write(path, value) do
    case File.write(path, value) do
      :ok ->
        :ok

      {:error, reason} = err ->
        Logger.warning("could not write #{path}: #{inspect(reason)}")
        err
    end
  end
end
