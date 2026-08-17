defmodule MayonnaiOS do
  @moduledoc """
  Entry points for driving the UI by hand.

  Scenic is deliberately not in the supervision tree by default: a failure at
  boot takes the whole application down, StartupGuard never validates, and the
  device reverts to the other firmware slot -- taking the error message with
  it. Starting it from an SSH session keeps the failure where it can be read.
  """

  @doc """
  Start the Scenic viewport, returning whatever the supervisor returns.
  """
  def start_ui do
    # Scenic.start_link/1 takes a *list* of viewport configs, not one config.
    # Passing the config bare fails with a Protocol.UndefinedError on Tuple,
    # which does not obviously point at the arity.
    Scenic.start_link([Application.get_env(:mayonnaios, :viewport)])
  end

  @doc """
  Facts about the framebuffer, for checking the panel before blaming Scenic.
  """
  def fb_info do
    read = fn f ->
      case File.read("/sys/class/graphics/fb0/#{f}") do
        {:ok, v} -> String.trim(v)
        _ -> "(missing)"
      end
    end

    %{
      device: File.exists?("/dev/fb0"),
      size: read.("virtual_size"),
      bpp: read.("bits_per_pixel"),
      stride: read.("stride"),
      driver_binary: driver_path(),
      dri: File.ls("/dev/dri")
    }
  end

  defp driver_path do
    case :code.priv_dir(:scenic_driver_local) do
      {:error, _} -> "(scenic_driver_local not loaded)"
      dir -> Path.join(dir, "scenic_driver_local")
    end
  end
end
