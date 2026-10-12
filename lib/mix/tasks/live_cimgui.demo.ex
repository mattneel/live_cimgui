defmodule Mix.Tasks.LiveCimgui.Demo do
  @shortdoc "Starts the demo window and blocks until it closes"

  @moduledoc """
  Starts the demo window and blocks until it closes.

      mix live_cimgui.demo

  The task starts the application (therefore `LiveCimgui.HostSupervisor` and the
  application service), starts the demo through `LiveCimgui.Demo.start/1`,
  prints the manager pid and its registered name, and then blocks until the
  manager exits. The manager exits when the window is closed
  (`LiveCimgui.Demo.stop/1`, which the window's close control runs), when
  someone calls `LiveCimgui.Demo.stop/1` from another shell, or when it
  exhausts its restart policy.

  The blocking strategy is a `Process.monitor/1` on the manager followed by a
  single `receive` of its `:DOWN` message: this task's process is what `mix`
  waits for, so `mix` lives exactly as long as the manager does and halts
  normally when the window closes — the same observable behaviour as
  `mix run --no-halt`, but tied to the window's lifetime instead of to an
  empty receive loop.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case LiveCimgui.Demo.start() do
      {:ok, manager} ->
        Mix.shell().info(
          "live_cimgui demo manager: #{inspect(manager)} " <>
            "(registered as #{inspect(LiveCimgui.Demo.manager())})"
        )

        reference = Process.monitor(manager)

        receive do
          {:DOWN, ^reference, :process, ^manager, reason} ->
            Mix.shell().info("live_cimgui demo manager exited: #{inspect(reason)}")
        end

      {:error, reason} ->
        Mix.raise("cannot start the live_cimgui demo: #{inspect(reason)}")
    end
  end
end
