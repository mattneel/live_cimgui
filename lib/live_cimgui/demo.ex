defmodule LiveCimgui.Demo do
  @moduledoc """
  Public API for the demo window — the IEx entry point of this project.

  The window is a thin facade over three processes and nothing else:

      LiveCimgui.Demo.start()
      # ... the real window is open ...
      LiveCimgui.Demo.rows()
      LiveCimgui.Demo.add_row()
      LiveCimgui.Demo.set_text("alpha", "  from IEx  ")
      LiveCimgui.Demo.restart_view()
      LiveCimgui.Demo.stop()

  * `LiveCimgui.Demo.State` — the application service (rows, load runs);
  * `LiveCimgui.Demo.View` — the view process driving the native description;
  * `LiveCimgui.HostManager` — the manager owning the native host, started under
    `LiveCimgui.HostSupervisor`.

  Every command here mutates the application service, whose broadcast is what
  makes the window redraw; nothing in this module talks to the native host
  except `inspect/0`, `restart_host/0`, and `restart_view/0`, which are exactly
  the manager's own control paths. `mix live_cimgui.demo` is the same demo from
  the command line.
  """

  alias LiveCimgui.Demo.State
  alias LiveCimgui.Demo.View
  alias LiveCimgui.HostManager
  alias LiveCimgui.HostSupervisor

  @manager LiveCimgui.Demo.Manager

  @doc """
  Starts the demo manager and its window.

  The manager is started under `LiveCimgui.HostSupervisor` (part of the
  application supervision tree, so `mix`/`iex -S mix` has it running already) and
  registered as `#{inspect(@manager)}` unless `:name` says otherwise:

      {:ok, manager} = LiveCimgui.Demo.start()
      {:ok, manager} = LiveCimgui.Demo.start(name: MyApp.Demo, width: 1280, height: 800)

  Options: `:name`, `:state` (application service to bind the view to, default
  `LiveCimgui.Demo.State`), `:width`, `:height`, `:restart_limit`,
  `:restart_window_ms`, `:executable`.

  Returns `{:error, reason}` when the native host cannot be started (for example
  when `priv/native/live_cimgui_host` has not been built — `mix compile` builds
  it).
  """
  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts \\ []) do
    host_opts =
      [
        name: Keyword.get(opts, :name, @manager),
        view: View,
        params: %{state: Keyword.get(opts, :state, State)},
        title: View.title()
      ]
      |> put_optional(opts, [:width, :height, :restart_limit, :restart_window_ms, :executable])

    DynamicSupervisor.start_child(HostSupervisor, {HostManager, host_opts})
  end

  @doc """
  Stops a demo manager and its window.

      :ok = LiveCimgui.Demo.stop()

  The view process is told to leave first (`{:demo_state, :stopping}`), because
  the view contract has no termination callback and the manager would otherwise
  leave it subscribed and running; then the manager is closed, which closes the
  native host. Accepts the registered name (default) or a pid.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(manager \\ @manager) do
    view_pid = manager |> HostManager.status() |> Map.get(:view_pid)

    if is_pid(view_pid) do
      send(view_pid, {:demo_state, :stopping})
      await_processed(view_pid)
    end

    :ok = HostManager.close(manager)

    if is_pid(view_pid), do: Process.exit(view_pid, :kill)
    :ok
  end

  @doc """
  The registered name of the default demo manager.

      LiveCimgui.Demo.manager()
      #=> LiveCimgui.Demo.Manager
  """
  @spec manager() :: atom()
  def manager, do: @manager

  @doc """
  Host and view bookkeeping: readiness, generations, UI revision, queue depths,
  dropped/stale messages, restarts, transport counters, and the last native
  diagnostics frame.

      LiveCimgui.Demo.status().ready
      #=> true
  """
  @spec status(GenServer.server()) :: map()
  def status(manager \\ @manager), do: HostManager.status(manager)

  @doc """
  The application snapshot the window is rendering.

      LiveCimgui.Demo.state()
      #=> %{rows: [%{key: "alpha", incarnation: 1, text: "Alpha"}, ...], load_runs: 0, ...}
  """
  @spec state() :: State.snapshot()
  def state, do: State.snapshot()

  @doc """
  The application rows, in application order.

      LiveCimgui.Demo.rows()
      #=> [%{key: "alpha", incarnation: 1, text: "Alpha"}, ...]
  """
  @spec rows() :: [State.row()]
  def rows, do: State.rows()

  @doc """
  Appends a row to the application service; the window redraws from the
  broadcast.

      {:ok, %{key: "row-1", incarnation: 1, text: "Row 1"}} = LiveCimgui.Demo.add_row()
  """
  @spec add_row() :: {:ok, State.row()} | {:error, State.error()}
  def add_row, do: State.add_row()

  @doc """
  Removes the last application row.

      {:ok, %{key: "row-1"}} = LiveCimgui.Demo.remove_row()
  """
  @spec remove_row() :: {:ok, State.row()} | {:error, State.error()}
  def remove_row, do: State.remove_row()

  @doc """
  Reverses application order. Keys and incarnations travel with their rows, so
  the native editors keep their text, caret, and selection.

      :ok = LiveCimgui.Demo.reverse()
  """
  @spec reverse() :: :ok
  def reverse, do: State.reverse_rows()

  @doc """
  Replaces the text of the row with `key`, resolving the row's current
  incarnation first. The application service normalizes the text.

      :ok = LiveCimgui.Demo.set_text("alpha", "  renamed  ")
      LiveCimgui.Demo.rows() |> hd() |> Map.fetch!(:text)
      #=> "renamed"

  Returns `{:error, :not_found}` when no row has that key.
  """
  @spec set_text(String.t(), String.t()) :: :ok | {:error, State.error()}
  def set_text(key, text) do
    case Enum.find(State.rows(), &(&1.key == key)) do
      nil -> {:error, :not_found}
      row -> State.set_text(row.key, row.incarnation, text)
    end
  end

  @doc """
  Runs the five-second load in the calling process and records one load run.

      :ok = LiveCimgui.Demo.busy()   # returns after five seconds

  This is the same code path the window's `busy` button runs
  (`LiveCimgui.Demo.View.run_busy/0`, five seconds of `Process.sleep/1` followed
  by `LiveCimgui.Demo.State.record_load_run/1`), invoked from IEx instead of from
  the view process because the framework's test-input path injects pointer and
  text input, not button identity. The window stays interactive while it runs.
  """
  @spec busy() :: :ok | {:error, State.error()}
  def busy, do: View.run_busy()

  @doc """
  Asks the manager to restart the view process (fault injection through the
  manager's control path; the view never restarts itself). The window survives:
  the manager keeps the native host and rebuilds it from the last description.

      :ok = LiveCimgui.Demo.restart_view()
  """
  @spec restart_view() :: :ok
  def restart_view, do: HostManager.restart_view(@manager)

  @doc """
  Kills the native host; the manager replaces it within its bounded restart
  policy and rebuilds the window from the last validated description.

      :ok = LiveCimgui.Demo.restart_host()
  """
  @spec restart_host() :: :ok
  def restart_host, do: HostManager.restart_host(@manager)

  @doc """
  Native widget state straight from the host: per-widget text, caret, selection,
  focus, draft and acknowledged revisions, and the geometry of the interactive
  items submitted in the last frame.

      {:ok, %{widgets: widgets}} = LiveCimgui.Demo.inspect()
      Enum.map(widgets, & &1.id)
      #=> ["draft", "alpha", "bravo", "charlie", "busy", "reverse", "add", "remove", "restart-view"]
  """
  @spec inspect() :: {:ok, map()} | {:error, term()}
  def inspect, do: HostManager.inspect_host(@manager)

  defp put_optional(host_opts, opts, keys) do
    Enum.reduce(keys, host_opts, fn key, acc ->
      case Keyword.fetch(opts, key) do
        {:ok, value} -> Keyword.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  # Bounded barrier: the view may be inside its deliberate five-second busy
  # callback, in which case the call times out and the unsubscribe happens when
  # the view reaches the message — or not at all if the view is killed below,
  # where the application service's dead-subscriber pruning covers it.
  defp await_processed(view_pid) do
    LiveCimgui.ViewServer.checkpoint(view_pid)
    :ok
  catch
    :exit, _reason -> :ok
  end
end
