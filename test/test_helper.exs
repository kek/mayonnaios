# Shared test doubles. Required here rather than compiled through
# `elixirc_paths` so that nothing in `test/support` can end up in the release
# by way of a mix.exs change nobody remembers making.
Code.require_file("support/fake_controller.exs", __DIR__)

ExUnit.start()
