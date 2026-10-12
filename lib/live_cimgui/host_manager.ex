defmodule LiveCimgui.HostManager do
  @moduledoc """
  Owns one native host: the Zigler resource, the window, and the protocol
  conversation with the native process.

  ## Why a separate process

  The manager exists so that native lifetime is independent of application
  lifetime in both directions:

    * a view process that blocks for seconds (or crashes) never stalls the
      transport: the manager is the only process that submits frames, and the
      NIF reader thread delivers native events to it;
    * a native host that dies does not touch the BEAM or the application
      service: the manager reports it, restarts the host within a bounded
      policy, and rebuilds the window from the last description.

  ## Responsibilities

    * the native resource returned by `LiveCimgui.Native.open/3` (closing it is
      idempotent, and an obsolete resource can never close a replacement host);
    * the view generation counter: every `register_view/2` bumps it, and native
      messages carrying an older generation are rejected;
    * the UI revision counter and the last validated description (what a fresh
      host or a restarted view is rebuilt from);
    * ordered event delivery with one event in flight per view, coalescing only
      adjacent text edits (never button clicks);
    * explicit overload accounting for every queue that can saturate.
  """

  use GenServer

  require Logger

  alias LiveCimgui.Native
  alias LiveCimgui.Protocol
  alias LiveCimgui.UI
  alias LiveCimgui.ViewServer

  @max_pending_events 256
  @view_restart_limit 5
  @view_restart_window_ms 5_000
  @retry_interval_ms 25
  @default_restart_limit 3
  @default_restart_window_ms 5_000
  @default_width 940
  @default_height 620

  defmodule Pending do
    @moduledoc false
    # Replaceable snapshots and ordered commands waiting for native queue space.
    defstruct events: [], snapshot: nil, acks: %{}, values: [], retry_timer: nil
  end

  defmodule Counters do
    @moduledoc false
    # Manager-side pressure accounting, exposed through `diagnostics/1`.
    defstruct dropped: 0, stale: 0, overloads: []
  end

  defmodule State do
    @moduledoc false
    defstruct session_id: nil,
              host_generation: 0,
              view_generation: 0,
              resource: nil,
              executable: nil,
              title: "live_cimgui",
              width: 940,
              height: 620,
              ready: false,
              view: nil,
              view_module: nil,
              view_params: %{},
              view_session: %{},
              view_supervisor: nil,
              monitor: nil,
              restart_times: [],
              view_restart_times: [],
              restart_limit: 3,
              restart_window_ms: 5_000,
              ui_revision: 0,
              last_checkpoint: %{},
              last_node: nil,
              in_flight: nil,
              pending: %Pending{},
              counters: %Counters{},
              next_request_id: 1,
              inspect_requests: %{},
              diagnostics: %{},
              last_drafts_signature: nil
  end

  ## Public API

  @doc """
  Starts a host manager.

  Options:

    * `:name` — registered name (optional)
    * `:view` — view module to supervise (optional; `start_view/2` otherwise)
    * `:params`, `:session` — passed to the view's `mount/3`
    * `:executable` — host executable path; defaults to `LiveCimgui.Native.host_executable/0`
    * `:title`, `:width`, `:height` — window identity
    * `:restart_limit`, `:restart_window_ms` — bounded host restart policy
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @doc """
  Child specification for a supervised manager.

  `:transient` on purpose: a *normal* stop (which is what
  `Livecimgui.HostManager.close/1` performs) must not resurrect a window, while a
  manager that crashes still gets a replacement from its supervisor.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  @doc """
  Registers a view process and issues a fresh view generation.

  Returns the generation and the presentation checkpoint of the previous view
  incarnation, so a replacement view resumes where the crashed one stopped.
  """
  @spec register_view(GenServer.server(), pid()) :: {:ok, non_neg_integer(), map()}
  def register_view(manager, view_pid) when is_pid(view_pid) do
    GenServer.call(manager, {:register_view, view_pid})
  end

  @doc """
  Publishes a validated description for a view generation.

  The manager assigns the UI revision. A stale generation (a view that already
  lost its generation to a replacement) returns `{:error, :stale_view}`; the
  view process should stop rather than keep publishing.
  """
  @spec render(GenServer.server(), map(), map(), UI.Node.t()) :: :ok | {:error, :stale_view}
  def render(manager, view, checkpoint, node) do
    GenServer.call(manager, {:render, view, checkpoint, node}, 30_000)
  end

  @doc "Acknowledges the highest draft revision accepted for a widget."
  @spec acknowledge(
          GenServer.server(),
          non_neg_integer(),
          String.t(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          :ok
  def acknowledge(manager, generation, id, incarnation, revision) do
    GenServer.call(manager, {:acknowledge, generation, id, incarnation, revision}, 30_000)
  end

  @doc """
  Explicitly replaces a field's text (an application-driven change, as opposed
  to a draft acknowledgement).

  `base_revision` is the draft revision the application believes is current; the
  host applies the replacement according to the conflict policy in
  `docs/PROTOCOL.md`.
  """
  @spec set_value(
          pid(),
          non_neg_integer(),
          String.t(),
          non_neg_integer(),
          String.t(),
          non_neg_integer()
        ) :: :ok
  def set_value(manager, generation, id, incarnation, text, base_revision \\ 0) do
    GenServer.call(
      manager,
      {:set_value, generation, id, incarnation, text, base_revision},
      30_000
    )
  end

  @doc """
  Asks the native host for its current widget state: text, caret, selection,
  focus, draft and acknowledged revisions, plus the geometry of the interactive
  items submitted in the last frame.
  """
  @spec inspect_host(GenServer.server(), timeout()) :: {:ok, map()} | {:error, term()}
  def inspect_host(manager, timeout \\ 5_000) do
    GenServer.call(manager, {:inspect, timeout}, timeout + 1_000)
  end

  @doc "Latest native diagnostics frame, plus manager-side counters."
  @spec diagnostics(GenServer.server()) :: map()
  def diagnostics(manager), do: GenServer.call(manager, :diagnostics)

  @doc "Host and view bookkeeping useful for tests and for `mix live_cimgui.demo`."
  @spec status(GenServer.server()) :: map()
  def status(manager), do: GenServer.call(manager, :status)

  @doc """
  Fault-injection path: stops the current native host as if it had crashed.

  This is a *separate control path* from application commands, so tests can
  prove host recovery without asking a (possibly stalled) view to cooperate.
  """
  @spec restart_host(GenServer.server(), atom()) :: :ok
  def restart_host(manager, mode \\ :kill) when mode in [:kill, :close],
    do: GenServer.call(manager, {:restart_host, mode})

  @doc "Stops the current view process (the supervisor replaces it with a fresh generation)."
  @spec restart_view(GenServer.server()) :: :ok
  def restart_view(manager), do: GenServer.call(manager, :restart_view)

  @doc "Starts a view under this manager (usually called from the manager itself)."
  @spec start_view(GenServer.server(), module(), map(), map()) :: {:ok, pid()} | {:error, term()}
  def start_view(manager, module, params \\ %{}, session \\ %{}) do
    GenServer.call(manager, {:start_view, module, params, session})
  end

  @doc """
  Test-only control path: injects input or a fault into the native host.

  These messages use the protocol's test namespace (`test_input`, `fault`) and
  are never generated by application code, so GUI acceptance tests can drive the
  real window and exercise host failure without the view having to cooperate.
  """
  @spec inject(GenServer.server(), tuple()) :: :ok | {:error, term()}
  def inject(manager, message) when is_tuple(message),
    do: GenServer.call(manager, {:inject, message})

  @doc "Closes the native host and stops the manager."
  @spec close(GenServer.server()) :: :ok
  def close(manager), do: GenServer.stop(manager, :normal, 5_000)

  ## GenServer

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %State{
      session_id: session_id(),
      executable: Keyword.get(opts, :executable, Native.host_executable()),
      title: Keyword.get(opts, :title, "live_cimgui"),
      width: Keyword.get(opts, :width, @default_width),
      height: Keyword.get(opts, :height, @default_height),
      restart_limit: Keyword.get(opts, :restart_limit, @default_restart_limit),
      restart_window_ms: Keyword.get(opts, :restart_window_ms, @default_restart_window_ms),
      view_params: Keyword.get(opts, :params, %{}),
      view_session: Keyword.get(opts, :session, %{})
    }

    {:ok, supervisor} =
      DynamicSupervisor.start_link(strategy: :one_for_one, max_children: 4)

    state = %{state | view_supervisor: supervisor}

    case open_host(state) do
      {:ok, state} ->
        case Keyword.get(opts, :view) do
          nil -> {:ok, state}
          module -> {:ok, state, {:continue, {:start_view, module}}}
        end

      {:error, reason} ->
        {:stop, {:host_unavailable, reason}}
    end
  end

  @impl GenServer
  def handle_continue({:start_view, module}, state) do
    # The view's `init/1` registers with this manager, so it must not be started
    # from inside a manager callback: doing so would deadlock on `register_view/2`.
    state = %{state | view_module: module}
    spawn_view_async(state, module)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:register_view, pid}, _from, state) do
    generation = state.view_generation + 1
    monitor = Process.monitor(pid)
    if state.monitor, do: Process.demonitor(state.monitor, [:flush])

    # Delayed updates from the previous generation must not resurrect state.
    dropped = length(state.pending.events)

    state = %{
      state
      | view_generation: generation,
        view: %{pid: pid, generation: generation},
        monitor: monitor,
        in_flight: nil,
        pending: %{state.pending | events: [], snapshot: nil},
        counters: %{state.counters | dropped: state.counters.dropped + dropped}
    }

    if dropped > 0 do
      Logger.warning("live_cimgui view restart dropped #{dropped} queued native events")
    end

    Logger.info("live_cimgui view generation #{generation} registered (#{inspect(pid)})")
    {:reply, {:ok, generation, state.last_checkpoint}, state}
  end

  def handle_call({:render, view, checkpoint, node}, _from, state) do
    cond do
      state.view == nil or view.pid != state.view.pid ->
        {:reply, {:error, :stale_view}, state}

      view.generation != state.view_generation ->
        {:reply, {:error, :stale_view}, state}

      true ->
        state = %{
          state
          | last_checkpoint: checkpoint,
            last_node: node,
            ui_revision: state.ui_revision + 1
        }

        state = publish_snapshot(state)
        state = maybe_finish_in_flight(state, view)

        {:reply, :ok, state}
    end
  end

  def handle_call({:acknowledge, generation, id, incarnation, revision}, _from, state) do
    if generation == state.view_generation do
      {:reply, :ok, queue_ack(state, id, incarnation, revision)}
    else
      {:reply, :ok, bump(state, :stale)}
    end
  end

  def handle_call({:set_value, generation, id, incarnation, text, base_revision}, _from, state) do
    if generation == state.view_generation do
      {:reply, :ok, queue_value(state, id, incarnation, text, base_revision)}
    else
      {:reply, :ok, bump(state, :stale)}
    end
  end

  def handle_call({:inspect, timeout}, from, state) do
    request_id = state.next_request_id
    frame = Protocol.encode!({:inspect, request_id})

    case submit(state, frame) do
      :ok ->
        # The reply is delivered when the native `inspect_result` arrives; the
        # caller's own call timeout bounds the wait.
        state = %{
          state
          | next_request_id: request_id + 1,
            inspect_requests: Map.put(state.inspect_requests, request_id, {from, timeout})
        }

        {:noreply, state}

      other ->
        {:reply, {:error, other}, state}
    end
  end

  def handle_call({:inject, message}, _from, state) do
    frame = Protocol.encode!(message)

    case submit(state, frame) do
      :ok -> {:reply, :ok, state}
      other -> {:reply, {:error, other}, state}
    end
  end

  def handle_call(:diagnostics, _from, state) do
    {:reply, manager_diagnostics(state), state}
  end

  def handle_call(:status, _from, state) do
    status = %{
      session_id: state.session_id,
      host_generation: state.host_generation,
      view_generation: state.view_generation,
      ready: state.ready,
      ui_revision: state.ui_revision,
      view_pid: state.view && state.view.pid,
      pending_events: length(state.pending.events),
      pending_acks: map_size(state.pending.acks),
      pending_values: length(state.pending.values),
      pending_snapshot: state.pending.snapshot != nil,
      in_flight: state.in_flight != nil,
      dropped_events: state.counters.dropped,
      stale_messages: state.counters.stale,
      overloads: Enum.reverse(state.counters.overloads),
      last_overload: List.first(state.counters.overloads),
      diagnostics: state.diagnostics,
      transport: transport_counters(state),
      restarts: state.restart_times,
      mailbox: Process.info(self(), :message_queue_len)
    }

    {:reply, status, state}
  end

  def handle_call({:restart_host, mode}, _from, state) do
    case force_host_restart(state, mode) do
      {:ok, state} -> {:reply, :ok, state}
      {:stop, reason, state} -> {:stop, reason, state}
    end
  end

  def handle_call(:restart_view, _from, state) do
    if state.view do
      Process.exit(state.view.pid, :kill)
    end

    {:reply, :ok, state}
  end

  def handle_call({:start_view, module, params, session}, _from, state) do
    state = %{state | view_module: module, view_params: params, view_session: session}
    spawn_view_async(state, module)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:live_cimgui_native, session_id, frame}, state) do
    if session_id == state.session_id do
      handle_native_frame(state, frame)
    else
      Logger.debug(
        "live_cimgui dropped a frame from another session (#{inspect(session_id)} != #{inspect(state.session_id)})"
      )

      {:noreply, bump(state, :stale)}
    end
  end

  def handle_info({:live_cimgui_native_error, session_id, reason}, state) do
    if session_id == state.session_id do
      Logger.warning("live_cimgui native transport error: #{inspect(reason)}")
      host_failed_reply(state, reason)
    else
      Logger.debug(
        "live_cimgui dropped a transport error from another session (#{inspect(session_id)} != #{inspect(state.session_id)})"
      )

      {:noreply, bump(state, :stale)}
    end
  end

  def handle_info(:flush_pending, state) do
    {:noreply, flush_pending(%{state | pending: %{state.pending | retry_timer: nil}})}
  end

  def handle_info(
        {:DOWN, monitor, :process, pid, reason},
        %{monitor: monitor, view: %{pid: pid}} = state
      ) do
    Logger.warning("live_cimgui view crashed: #{inspect(reason)}; native host stays alive")

    state = %{
      state
      | view: nil,
        monitor: nil,
        in_flight: nil,
        pending: %{state.pending | events: []}
    }

    now = System.monotonic_time(:millisecond)
    window = state.view_restart_times |> Enum.filter(&(now - &1 < @view_restart_window_ms))
    restarts = [now | window]
    state = %{state | view_restart_times: restarts}

    cond do
      state.view_module == nil ->
        {:noreply, state}

      length(restarts) > @view_restart_limit ->
        Logger.error(
          "live_cimgui: view crashed #{length(restarts)} times in #{@view_restart_window_ms}ms; giving up"
        )

        {:stop, {:shutdown, :view_restart_intensity}, state}

      true ->
        spawn_view_async(state, state.view_module)
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _monitor, :process, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, reason}, %{view_supervisor: pid} = state) do
    {:stop, {:view_supervisor_exit, reason}, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(message, state) do
    Logger.debug("live_cimgui manager ignoring #{inspect(message)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, state) do
    if state.resource, do: Native.close(state.resource)
    Logger.debug("live_cimgui host manager stopping: #{inspect(reason)}")
    :ok
  end

  ## Native message handling

  defp handle_native_frame(state, frame) do
    case Protocol.decode(frame) do
      {:ok, message} ->
        apply_native_message(state, message)

      {:error, reason} ->
        Logger.error("live_cimgui rejected native frame: #{inspect(reason)}")
        {:noreply, bump(state, :stale)}
    end
  end

  defp apply_native_message(state, {:ready, info}) do
    Logger.info(
      "live_cimgui native host ready: #{info.sdl_version} / #{info.gl_renderer} (host generation #{info.host_generation})"
    )

    state = %{state | ready: true, diagnostics: Map.put(state.diagnostics, :ready, info)}
    # A fresh host (or a fresh view) is rebuilt from the last validated
    # description.
    {:noreply, publish_snapshot(%{state | pending: %{state.pending | snapshot: nil}})}
  end

  defp apply_native_message(state, {:event, generation, revision, event}) do
    if generation == state.view_generation and state.view != nil do
      {:noreply, enqueue_event(state, revision, event)}
    else
      Logger.debug(
        "live_cimgui dropped event from generation #{generation} (current #{state.view_generation})"
      )

      {:noreply, bump(state, :stale)}
    end
  end

  defp apply_native_message(state, {:diagnostics, diagnostics}) do
    {:noreply, %{state | diagnostics: diagnostics}}
  end

  defp apply_native_message(state, {:drafts, generation, drafts}) do
    signature = drafts_signature(drafts)

    if generation == state.view_generation and state.view != nil and drafts != [] and
         signature != state.last_drafts_signature do
      # Forwarding an identical draft set would make a view that re-renders on
      # every message render forever; the signature keeps the handshake one-shot.
      send(state.view.pid, {:live_cimgui, :drafts, drafts})
      {:noreply, %{state | last_drafts_signature: signature}}
    else
      {:noreply, state}
    end
  end

  defp apply_native_message(state, {:overload, overload}) do
    Logger.warning(
      "live_cimgui native overload #{overload.code}: #{overload.detail} (dropped #{overload.dropped})"
    )

    overloads = Enum.take([overload | state.counters.overloads], 32)
    {:noreply, %{state | counters: %{state.counters | overloads: overloads}}}
  end

  defp apply_native_message(state, {:inspect_result, %{request_id: request_id} = result}) do
    case Map.pop(state.inspect_requests, request_id) do
      {nil, _} ->
        {:noreply, state}

      {{from, _timeout}, remaining} ->
        GenServer.reply(from, {:ok, result})
        {:noreply, %{state | inspect_requests: remaining}}
    end
  end

  defp apply_native_message(state, {:pong, _request_id}), do: {:noreply, state}

  defp apply_native_message(state, {:bye, info}) do
    Logger.info("live_cimgui native host said goodbye: #{inspect(info)}")
    host_failed_reply(state, {:host_exit, info})
  end

  defp apply_native_message(state, {:protocol_error, info}) do
    Logger.error("live_cimgui native protocol error: #{inspect(info)}")
    host_failed_reply(state, {:protocol_error, info})
  end

  @doc false
  def drafts_signature(drafts) do
    drafts
    |> Enum.map(&{Map.get(&1, :id), Map.get(&1, :incarnation), Map.get(&1, :draft_revision)})
    |> Enum.sort()
    |> :erlang.phash2()
  end

  ## Event delivery: one event in flight per view, ordered, bounded

  defp enqueue_event(state, revision, event) do
    pending = coalesce_event(state.pending.events, event)

    if length(pending) > @max_pending_events do
      Logger.error(
        "live_cimgui view event queue saturated at #{@max_pending_events}; reporting overload"
      )

      state = bump(state, :dropped)
      state = queue_overload_notice(state)
      dispatch_events(state)
    else
      dispatch_events(%{
        state
        | pending: %{state.pending | events: pending},
          diagnostics: Map.put(state.diagnostics, :event_revision, revision)
      })
    end
  end

  @doc false
  # Only replaceable drafts coalesce, and only with their immediate predecessor:
  # an intervening click keeps both sides distinct, exactly like the native side.
  def coalesce_event(events, event) do
    case {List.last(events), event} do
      {{:input_edit, id, incarnation, _old_revision, _old_text},
       {:input_edit, id, incarnation, revision, text}} ->
        List.replace_at(events, -1, {:input_edit, id, incarnation, revision, text})

      _ ->
        events ++ [event]
    end
  end

  defp dispatch_events(%{in_flight: nil, view: %{pid: pid}} = state) do
    case state.pending.events do
      [] ->
        state

      [event | rest] ->
        render_ref = make_ref()
        send(pid, {:live_cimgui_event, render_ref, event})
        %{state | in_flight: %{ref: render_ref}, pending: %{state.pending | events: rest}}
    end
  end

  defp dispatch_events(state), do: state

  defp maybe_finish_in_flight(%{in_flight: %{ref: ref}} = state, %{render_ref: ref}) do
    state |> Map.put(:in_flight, nil) |> dispatch_events()
  end

  defp maybe_finish_in_flight(state, _view), do: dispatch_events(state)

  ## Publishing

  defp publish_snapshot(%{last_node: nil} = state), do: state

  defp publish_snapshot(%{ready: false} = state), do: state

  defp publish_snapshot(state) do
    revision = max(state.ui_revision, 1)
    frame = Protocol.encode!({:snapshot, state.view_generation, revision, state.last_node})

    case submit(state, frame) do
      :ok ->
        %{state | pending: %{state.pending | snapshot: nil}}

      :overloaded ->
        %{
          state
          | pending: %{
              state.pending
              | snapshot: {state.view_generation, revision, state.last_node}
            }
        }
        |> schedule_retry()

      :closed ->
        state

      :malformed ->
        state
    end
  end

  defp queue_ack(state, id, incarnation, revision) do
    key = {id, incarnation}
    existing = Map.get(state.pending.acks, key, 0)

    if revision > existing do
      state
      |> Map.put(:pending, %{state.pending | acks: Map.put(state.pending.acks, key, revision)})
      |> flush_pending()
      |> schedule_retry()
    else
      state
    end
  end

  defp queue_value(state, id, incarnation, text, base_revision) do
    entry = {state.view_generation, id, incarnation, base_revision, text}
    values = state.pending.values ++ [entry]

    if length(values) > @max_pending_events do
      Logger.error("live_cimgui application value queue saturated; reporting overload")
      state |> bump(:dropped) |> queue_overload_notice()
    else
      state
      |> Map.put(:pending, %{state.pending | values: values})
      |> flush_pending()
      |> schedule_retry()
    end
  end

  defp queue_overload_notice(state) do
    overload = %{
      code: :view_queue_full,
      pending_events: length(state.pending.events),
      dropped_events: state.counters.dropped
    }

    notify_view(state, {:live_cimgui, :overload, overload})
  end

  defp schedule_retry(%{pending: %{retry_timer: nil}} = state) do
    %{
      state
      | pending: %{
          state.pending
          | retry_timer: Process.send_after(self(), :flush_pending, @retry_interval_ms)
        }
    }
  end

  defp schedule_retry(state), do: state

  defp flush_pending(state) do
    state
    |> flush_snapshot()
    |> flush_acks()
    |> flush_values()
  end

  defp flush_snapshot(%{pending: %{snapshot: nil}} = state), do: state

  defp flush_snapshot(%{pending: %{snapshot: {generation, revision, node}}} = state) do
    frame = Protocol.encode!({:snapshot, generation, revision, node})

    case submit(state, frame) do
      :ok -> %{state | pending: %{state.pending | snapshot: nil}}
      _ -> state
    end
  end

  # Acknowledgements are monotonic per widget, so only the highest revision per
  # {id, incarnation} is kept while the native queue is saturated. `pending_acks`
  # maps `{id, incarnation} => revision`.
  defp flush_acks(state) do
    Enum.reduce(state.pending.acks, state, fn {{id, incarnation}, revision}, acc ->
      frame = Protocol.encode!({:ack, state.view_generation, id, incarnation, revision})

      case submit(acc, frame) do
        :ok ->
          %{acc | pending: %{acc.pending | acks: Map.delete(acc.pending.acks, {id, incarnation})}}

        _ ->
          acc
      end
    end)
  end

  # Application value changes are ordered semantic commands: they are sent in
  # order and never coalesced away.
  defp flush_values(state) do
    Enum.reduce_while(state.pending.values, state, fn {generation, id, incarnation, base_revision,
                                                       text},
                                                      acc ->
      frame = Protocol.encode!({:set_value, generation, id, incarnation, base_revision, text})

      case submit(acc, frame) do
        :ok -> {:cont, %{acc | pending: %{acc.pending | values: tl(acc.pending.values)}}}
        _ -> {:halt, acc}
      end
    end)
  end

  ## Host lifecycle

  defp open_host(state) do
    case Native.open(state.executable, self(), state.session_id) do
      {:ok, resource} ->
        host_generation = state.host_generation + 1
        state = %{state | resource: resource, host_generation: host_generation, ready: false}

        hello =
          Protocol.encode!(
            {:hello, state.session_id, state.view_generation, host_generation, state.title,
             state.width, state.height}
          )

        case submit(state, hello) do
          :ok -> {:ok, state}
          :overloaded -> {:ok, state}
          :closed -> {:error, :closed}
          :malformed -> {:error, :malformed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Fault injection, deliberately separate from application commands. `:kill`
  # removes the process out from under the transport, exactly like a real host
  # crash; the transport then reports the failure through the normal path.
  # Returns `{:ok, state}` when the host was replaced or the failure was handed to
  # the normal failure path, and `{:stop, reason, state}` when the restart policy
  # refuses to continue.
  defp force_host_restart(state, mode) do
    Logger.warning("live_cimgui: forcing native host restart (#{mode})")

    case {mode, host_os_pid(state)} do
      {:kill, pid} when is_integer(pid) ->
        {_output, _status} = System.cmd("kill", ["-9", Integer.to_string(pid)])
        # The transport reports the dead host through the normal failure path.
        {:ok, state}

      {_mode, _pid} ->
        host_failed(state, :forced)
    end
  end

  defp host_failed_reply(state, reason) do
    case host_failed(state, reason) do
      {:ok, state} -> {:noreply, state}
      {:stop, stop_reason, state} -> {:stop, stop_reason, state}
    end
  end

  defp host_os_pid(state) do
    case Map.get(state.diagnostics, :ready) do
      %{pid: pid} when is_integer(pid) -> pid
      _ -> nil
    end
  end

  # Returns `{:ok, state}` after a successful bounded restart, or `{:stop, ...}`
  # when the restart policy refuses to keep going. The application service is
  # never touched: the manager and the host are the only things that change.
  defp host_failed(state, reason) do
    if state.resource, do: Native.close(state.resource)
    now = System.monotonic_time(:millisecond)
    window = state.restart_times |> Enum.filter(&(now - &1 < state.restart_window_ms))
    restarts = [now | window]
    state = %{state | resource: nil, ready: false, restart_times: restarts}

    if length(restarts) > state.restart_limit do
      Logger.error(
        "live_cimgui: native host failed #{length(restarts)} times in #{state.restart_window_ms}ms; giving up"
      )

      state = notify_view(state, {:live_cimgui, :host_unavailable, reason})
      {:stop, {:shutdown, :host_restart_intensity}, state}
    else
      attempt_restart(state, reason)
    end
  end

  defp attempt_restart(state, reason) do
    case open_host(state) do
      {:ok, state} ->
        notify_view(
          state,
          {:live_cimgui, :host_restarted,
           %{reason: reason, host_generation: state.host_generation}}
        )

        {:ok, publish_snapshot(state)}

      {:error, error} ->
        Logger.error("live_cimgui: cannot restart native host: #{inspect(error)}")
        notify_view(state, {:live_cimgui, :host_unavailable, error})
        {:ok, state}
    end
  end

  defp notify_view(%{view: nil} = state, _message), do: state

  defp notify_view(%{view: %{pid: pid}} = state, message) do
    send(pid, message)
    state
  end

  ## Helpers

  defp submit(%{resource: nil}, _frame), do: :closed

  defp submit(state, frame), do: Native.submit(state.resource, frame)

  # Starts the view process from a task, never from inside a manager callback:
  # the view's `init/1` performs a synchronous `register_view/2` call back into
  # this manager, which would otherwise deadlock.
  defp spawn_view_async(state, module) do
    manager = self()
    supervisor = state.view_supervisor
    params = state.view_params
    session = state.view_session

    Task.start(fn ->
      case start_view_process(manager, supervisor, module, params, session) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          Logger.error("live_cimgui cannot start view #{inspect(module)}: #{inspect(reason)}")
      end
    end)

    :ok
  end

  # Manager-side pressure counter. Kept in one place so every increment also
  # updates what `diagnostics/1` reports.
  defp bump(state, :dropped),
    do: %{state | counters: %{state.counters | dropped: state.counters.dropped + 1}}

  defp bump(state, :stale),
    do: %{state | counters: %{state.counters | stale: state.counters.stale + 1}}

  defp start_view_process(manager, supervisor, module, params, session) do
    spec = %{
      id: ViewServer,
      start:
        {ViewServer, :start_link,
         [[manager: manager, view: module, params: params, session: session]]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(supervisor, spec) do
      {:ok, pid} ->
        Logger.info("live_cimgui view #{inspect(module)} started (#{inspect(pid)})")
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp manager_diagnostics(state) do
    %{
      session_id: state.session_id,
      ready: state.ready,
      host_generation: state.host_generation,
      view_generation: state.view_generation,
      ui_revision: state.ui_revision,
      pending_events: length(state.pending.events),
      pending_acks: map_size(state.pending.acks),
      pending_values: length(state.pending.values),
      pending_snapshot: state.pending.snapshot != nil,
      dropped_events: state.counters.dropped,
      stale_messages: state.counters.stale,
      transport: transport_counters(state),
      native: state.diagnostics
    }
  end

  defp transport_counters(%{resource: nil}), do: %{}

  defp transport_counters(%{resource: resource}) do
    Native.counters(resource)
  rescue
    _error -> %{}
  end

  defp session_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
