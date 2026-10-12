defmodule LiveCimgui.Gui.FailureTest do
  @moduledoc """
  Real-window failure-path acceptance: view crash, host crash, the bounded host
  restart policy, and bounded queue pressure.

  These tests need a display (the manager sends `hello`, so a real window is
  opened) and are tagged `:gui`; run them with `mix live_cimgui.gui_test`.

  ## Timing

  A host failure costs about two seconds before its replacement is spawned:
  `Livecimgui.Native.close/1` never observes its child's exit status (the NIF's
  `waitpid` fails because ERTS has already reaped the child), so it always waits
  out its reap timeout and then sends `SIGKILL`. The bounded-restart test uses a
  restart window that exceeds that cost, and every wait in this file is a
  bounded poll rather than a sleep.
  """

  use ExUnit.Case, async: false

  @moduletag :gui
  @moduletag timeout: 300_000

  alias LiveCimgui.HostManager
  alias LiveCimgui.NativeHarness, as: Harness
  alias LiveCimgui.UI

  @buttons ~w(a b)
  @inject_budget_ms 90_000
  @inject_retries 5

  ## View

  defmodule FailureView do
    use LiveCimgui.View

    @impl LiveCimgui.View
    def mount(_params, session, socket) do
      {:ok,
       assign(socket,
         events: session[:events],
         stall_ms: session[:stall_ms] || 0,
         stall_events: session[:stall_events] || 0
       )}
    end

    @impl LiveCimgui.View
    def render(assigns) do
      UI.column([
        UI.text("failure suite"),
        UI.input("input", assigns[:input] || "", label: "input"),
        UI.row([UI.button("a", "A"), UI.button("b", "B")])
      ])
    end

    @impl LiveCimgui.View
    def handle_event(_name, _params, socket) do
      # `events` counts handled events in an Agent so that a replacement view
      # incarnation keeps counting. The stall is deliberate: the first
      # `stall_events` events sleep, which is how queue pressure is built.
      if events = socket.assigns[:events] do
        index = Agent.get_and_update(events, fn count -> {count, count + 1} end)

        if index < socket.assigns[:stall_events] do
          Process.sleep(socket.assigns[:stall_ms])
        end
      end

      {:noreply, socket}
    end
  end

  ## Tests

  test "a view crash keeps the window: the view is replaced, the host is not" do
    manager = start_window!(session: %{events: start_counter()})

    before_status = status(manager)
    before_inspect = inspect_host!(manager)

    assert before_status.ready
    assert before_status.view_generation >= 1
    assert before_inspect.frame_count > 0

    assert :ok = HostManager.restart_view(manager)

    after_status =
      Harness.wait_until(
        fn ->
          with %{} = current <- poll_status(manager),
               true <- current.view_generation > before_status.view_generation,
               true <- current.view_pid != before_status.view_pid do
            current
          end
        end,
        "the view was never replaced after restart_view/1"
      )

    after_inspect =
      Harness.wait_until(
        fn ->
          case HostManager.inspect_host(manager) do
            {:ok, result} -> if result.frame_count > before_inspect.frame_count, do: result
            {:error, _reason} -> nil
          end
        end,
        "the native frame counter never advanced after the view restarted"
      )

    assert after_status.host_generation == before_status.host_generation
    assert after_inspect.view_generation == after_status.view_generation
    assert {:ok, _result} = HostManager.inspect_host(manager)
  end

  test "a host crash keeps the application service and rebuilds the window" do
    {:ok, service} = Agent.start_link(fn -> :alive end)
    on_exit(fn -> if Process.alive?(service), do: Agent.stop(service) end)

    manager = start_window!(session: %{events: start_counter()})

    before_status = status(manager)
    before_inspect = inspect_host!(manager)

    assert before_status.ready
    assert before_inspect.applied_ui_revision > 0
    assert Enum.map(before_inspect.widgets, & &1.id) |> Enum.sort() == ["a", "b", "input"]

    assert :ok = HostManager.restart_host(manager, :kill)

    after_status =
      Harness.wait_until(
        fn ->
          with %{} = current <- poll_status(manager),
               true <- current.host_generation > before_status.host_generation,
               true <- current.ready do
            current
          end
        end,
        "the native host was never restarted after a crash"
      )

    assert Agent.get(service, & &1) == :alive

    rebuilt =
      Harness.wait_until(
        fn ->
          case HostManager.inspect_host(manager) do
            {:ok, result} ->
              if result.applied_ui_revision > 0 and result.widgets != [], do: result

            {:error, _reason} ->
              nil
          end
        end,
        "the description was never rebuilt on the fresh host"
      )

    assert Enum.map(rebuilt.widgets, & &1.id) |> Enum.sort() == ["a", "b", "input"]
    assert rebuilt.view_generation == after_status.view_generation
    assert is_map(status(manager))
  end

  test "the bounded host restart policy stops the manager instead of looping forever" do
    Process.flag(:trap_exit, true)

    manager =
      start_window!(
        restart_limit: 1,
        # A failed host costs ~2 s before its replacement is spawned (see the
        # moduledoc), so the window has to exceed the ticket's 2 s for two
        # failures to ever overlap.
        restart_window_ms: 4_000,
        session: %{events: start_counter()}
      )

    assert status(manager).host_generation == 1
    monitor = Process.monitor(manager)

    assert :ok = HostManager.inject(manager, {:fault, :crash})

    # Crash the replacement host too: two failures inside the window exceed
    # `restart_limit: 1`.
    Harness.wait_until(
      fn ->
        with %{} = current <- poll_status(manager),
             true <- current.host_generation > 1,
             true <- current.ready do
          current
        end
      end,
      "the host was not replaced after the first injected crash"
    )

    assert :ok = HostManager.inject(manager, {:fault, :crash})

    assert_receive {:DOWN, ^monitor, :process, ^manager, reason}, 60_000
    assert reason == {:shutdown, :host_restart_intensity}
  end

  test "queue pressure stays bounded and loud" do
    events = start_counter()

    manager = start_window!(session: %{events: events, stall_ms: 2_000, stall_events: 8})

    rects = await_rects!(manager)
    left = rect_center!(rects, "a")
    right = rect_center!(rects, "b")

    clicks = 400
    injections = inject_clicks(manager, left, right, clicks)

    dropped =
      Harness.wait_until(
        fn ->
          with %{} = current <- poll_status(manager),
               true <- current.dropped_events > 0 do
            current
          end
        end,
        "the view event queue never reported a drop",
        1_500
      )

    # Wait for the one-shot stall to finish and for the queue to drain, then
    # check that everything stayed bounded and that nothing was misattributed.
    drained =
      Harness.wait_until(
        fn ->
          with %{} = current <- poll_status(manager),
               true <- current.pending_events == 0,
               true <- current.in_flight == false do
            current
          end
        end,
        "the view never drained its event queue",
        3_000
      )

    handled = Agent.get(events, & &1)

    IO.puts("""
    queue pressure: injected #{injections.accepted}/#{clicks * 3} frames \
    (#{injections.rejected} rejected as overloaded), handled events=#{handled}, \
    pending_events=#{drained.pending_events}, dropped_events=#{drained.dropped_events} \
    (first drop seen at #{dropped.dropped_events}), overloads=#{length(drained.overloads)}, \
    stale_messages=#{drained.stale_messages}
    """)

    assert injections.accepted > 0
    assert drained.pending_events <= 256
    assert dropped.dropped_events > 0
    assert drained.dropped_events > 0
    assert drained.stale_messages == 0
    assert is_map(status(manager))
    assert {:ok, _result} = HostManager.inspect_host(manager)
  end

  ## Helpers

  defp start_counter do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)
    counter
  end

  defp start_window!(opts) do
    {:ok, manager} =
      HostManager.start_link(
        title: "failure-suite",
        view: FailureView,
        session: Keyword.get(opts, :session, %{}),
        restart_limit: Keyword.get(opts, :restart_limit, 100),
        restart_window_ms: Keyword.get(opts, :restart_window_ms, 120_000)
      )

    on_exit(fn -> stop_manager(manager) end)

    case await_ready(manager, 100) do
      :ready -> manager
      other -> flunk("the host manager never reached :ready (#{inspect(other)})")
    end
  end

  defp await_ready(manager, attempts) do
    Enum.reduce_while(1..attempts, :not_ready, fn _n, _acc ->
      case poll_status(manager) do
        %{ready: true} -> {:halt, :ready}
        nil -> Process.sleep(20) && {:cont, :not_ready}
        _status -> Process.sleep(20) && {:cont, :not_ready}
      end
    end)
  end

  defp status(manager), do: status(manager, :flunk)

  defp status(manager, on_stop) do
    HostManager.status(manager)
  catch
    # A manager inside a native restart blocks in `Native.close/1` for about two
    # seconds, so a call can outlive its timeout without the manager dying.
    :exit, {:timeout, _reason} ->
      :busy

    :exit, reason ->
      if on_stop == :flunk do
        flunk("the host manager stopped: #{inspect(reason)}")
      else
        :stopped
      end
  end

  # Non-raising status for polling: a status map, or nil while the manager is
  # busy inside a native restart or has stopped.
  defp poll_status(manager) do
    case status(manager, :tolerate) do
      current when is_map(current) -> current
      _other -> nil
    end
  end

  defp stop_manager(manager) do
    if Process.alive?(manager) do
      try do
        HostManager.close(manager)
      catch
        :exit, _reason -> Process.exit(manager, :kill)
      end
    end

    Harness.await_no_host_children()
  end

  defp inspect_host!(manager) do
    Harness.wait_until(
      fn ->
        case HostManager.inspect_host(manager) do
          {:ok, result} -> result
          {:error, _reason} -> nil
        end
      end,
      "the native host never answered inspect_host/2"
    )
  end

  defp await_rects!(manager) do
    Harness.wait_until(
      fn ->
        result = inspect_host!(manager)
        ids = MapSet.new(result.rects, & &1.id)

        if result.rects != [] and Enum.all?(@buttons, &MapSet.member?(ids, &1)), do: result
      end,
      "the interactive widgets never appeared in the native rects"
    )
  end

  defp rect_center!(rects, id) do
    rect = Enum.find(rects.rects, &(&1.id == id)) || flunk("no native rect for #{inspect(id)}")
    {min_x, min_y} = rect.min
    {max_x, max_y} = rect.max
    {(min_x + max_x) / 2, (min_y + max_y) / 2}
  end

  defp inject_clicks(manager, left, right, count) do
    deadline = System.monotonic_time(:millisecond) + @inject_budget_ms

    Enum.reduce_while(1..count, %{accepted: 0, rejected: 0}, fn index, acc ->
      step_injection(manager, index, {left, right}, acc, deadline)
    end)
  end

  defp step_injection(manager, index, {left, right}, acc, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:halt, acc}
    else
      {:cont, inject_click(manager, click_point(index, left, right), acc)}
    end
  end

  defp click_point(index, left, right) do
    if rem(index, 2) == 1, do: left, else: right
  end

  defp inject_click(manager, point, acc) do
    Enum.reduce([:move, :click, :release], acc, fn kind, inner ->
      message = {:test_input, :mouse, {kind, elem(point, 0), elem(point, 1)}}
      tally(inner, inject(manager, message, @inject_retries))
    end)
  end

  defp tally(acc, true), do: %{acc | accepted: acc.accepted + 1}
  defp tally(acc, false), do: %{acc | rejected: acc.rejected + 1}

  # Injected frames queue in the transport and in the host; a saturated bounded
  # queue answers `{:error, :overloaded}`, which is not a test failure but does
  # mean the frame was not delivered. Poll a few times before giving up.
  defp inject(_manager, _message, 0), do: false

  defp inject(manager, message, retries) do
    case HostManager.inject(manager, message) do
      :ok -> true
      {:error, _reason} -> Process.sleep(20) && inject(manager, message, retries - 1)
    end
  end
end
