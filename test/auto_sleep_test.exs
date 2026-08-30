defmodule MayonnaiOS.AutoSleepTest do
  use ExUnit.Case, async: false

  alias MayonnaiOS.AutoSleep

  setup do
    root = Path.join(System.tmp_dir!(), "auto-sleep-#{System.unique_integer([:positive])}")
    path = Path.join(root, "nested/auto_sleep")
    previous_path = Application.get_env(:mayonnaios, :auto_sleep_path)
    previous_default = Application.get_env(:mayonnaios, :auto_sleep)
    Application.put_env(:mayonnaios, :auto_sleep_path, path)
    Application.put_env(:mayonnaios, :auto_sleep, true)

    on_exit(fn ->
      restore(:auto_sleep_path, previous_path)
      restore(:auto_sleep, previous_default)
      File.rm_rf(root)
    end)

    %{path: path}
  end

  test "defaults to configuration when no choice has been stored" do
    assert AutoSleep.enabled?()
    Application.put_env(:mayonnaios, :auto_sleep, false)
    refute AutoSleep.enabled?()
  end

  test "set and toggle survive fresh reads", %{path: path} do
    assert AutoSleep.set(false) == :ok
    assert File.read!(path) == "disabled\n"
    refute AutoSleep.enabled?()

    assert AutoSleep.toggle() == {:ok, true}
    assert AutoSleep.enabled?()
  end

  test "unknown contents fall back instead of changing policy", %{path: path} do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "unfinished")
    assert AutoSleep.enabled?()
  end

  defp restore(key, nil), do: Application.delete_env(:mayonnaios, key)
  defp restore(key, value), do: Application.put_env(:mayonnaios, key, value)
end
