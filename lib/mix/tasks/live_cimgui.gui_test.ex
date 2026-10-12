defmodule Mix.Tasks.LiveCimgui.GuiTest do
  @shortdoc "Runs the real-window GUI acceptance tests"

  @moduledoc """
  Runs the acceptance tests that need a display, a real cimgui window, and the
  native host:

      mix live_cimgui.gui_test

  They are tagged `:gui` and excluded from the default `mix test` run. If no
  display is available they are skipped with an explicit message; GUI acceptance
  is then *unverified* rather than assumed (see `docs/TESTING.md`).

  Pass test names or line numbers through to `mix test`:

      mix live_cimgui.gui_test test/live_cimgui/gui/acceptance_test.exs:42
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    if Mix.env() != :test, do: Mix.raise("run this task in the test environment (MIX_ENV=test)")

    Mix.Task.run("compile", [])

    case display_available?() do
      true ->
        Mix.Task.run("test", ["--only", "gui" | args])

      false ->
        Mix.shell().info("""
        No display available (DISPLAY and WAYLAND_DISPLAY are unset): GUI acceptance is UNVERIFIED.
        Run these tests in a session with a display (X11, Wayland, or WSLg) to verify the window.
        """)

        Mix.Task.run("test", ["--exclude", "gui" | args])
    end
  end

  @doc "Whether a display that can host the window appears to be available."
  @spec display_available?() :: boolean()
  def display_available? do
    System.get_env("DISPLAY") not in [nil, ""] or
      System.get_env("WAYLAND_DISPLAY") not in [nil, ""]
  end
end
