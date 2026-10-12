defmodule LiveCimgui.Demo.View do
  @title "live_cimgui — Native interaction. Elixir application state."
  @draft_id "draft"
  @busy_ms 5_000

  @moduledoc """
  The stress-test view: a real native window whose contents are application
  state.

  ## The window, top to bottom

    1. the heading — the same string as the window title;
    2. the *draft* editor, a view-local text line. It is deliberately not
       application state: it is how the demo shows a native draft surviving a
       view restart (the host re-reports unacknowledged drafts to the
       replacement view, see `handle_info/2`);
    3. a keyed list of editors, one per application row. The keyed key, the
       widget id, and the widget incarnation all come from the row, so
       reversing the list never moves native state between rows and a deleted
       and recreated key can never be confused with its predecessor;
    4. the command buttons: `busy`, `reverse`, `add`, `remove`, `restart-view`;
    5. Elixir-side diagnostics: the view generation (read from `socket.private`
       through `LiveCimgui.PhoenixAdapter.private/2`), the completed load-run
       count, the last acknowledged draft revision this view has seen, the row
       count, and any notice;
    6. `LiveCimgui.UI.diagnostics/0`, the host-rendered block. Nothing here is
       faked: those counters are read from native state on every frame, which is
       what makes them meaningful while this view is blocked.

  ## The five-second callback

  The `busy` button blocks *this view process* for five seconds and then records
  one load run. The window stays interactive: the host manager, the NIF
  transport, and the native host are separate processes, so frames keep being
  presented and the host-rendered diagnostics keep advancing while this view's
  mailbox is stalled.

  ## Application service synchronisation

  `mount/3` subscribes to `LiveCimgui.Demo.State` and mirrors the snapshot into
  assigns; `handle_info/2` folds every `{:demo_state, snapshot}` broadcast into
  assigns (the view server renders after each message). Editor events for rows
  are written through `LiveCimgui.Demo.State.set_text/4`. A refusal — a stale
  incarnation after the row was deleted and recreated, an unknown key, a bound —
  becomes a `notice:` text node; it never crashes the view.

  ## Native drafts and the fold rule

  The host reports full widget state on every applied description. Only entries
  whose native draft is *ahead* of its acknowledged revision are real surviving
  drafts — an edit some previous view incarnation never acknowledged (the host
  would otherwise be reporting its settled widgets back to the view that just
  rendered them). `handle_info/2` folds exactly those: a surviving draft for a
  row goes through `LiveCimgui.Demo.State.set_text/4`, a surviving draft for the
  `draft` editor restores the view-local assign, and every fold is summarized in
  one `notice:` text node. Folding is idempotent: the application service does
  not broadcast a `set_text/4` that changes nothing, so re-folding the same
  drafts cannot re-render the window.

  ## Subscription lifetime

  A view process never receives a termination callback: `LiveCimgui.ViewServer`
  is a temporary process and `LiveCimgui.HostManager.restart_view/1` kills it
  outright. The subscription is therefore opened and closed through the same
  message path that drives refreshes: `mount/3` subscribes, and
  `{:demo_state, :stopping}` — sent by `LiveCimgui.Demo.stop/1` before the
  manager closes — unsubscribes and renders one last notice. The application
  service also prunes dead subscribers on every broadcast, so a killed view
  cannot leak one.
  """

  use LiveCimgui.View

  import LiveCimgui.UI

  alias LiveCimgui.Demo.State
  alias LiveCimgui.HostManager
  alias LiveCimgui.PhoenixAdapter

  @doc "The window title and the heading rendered by `render/1`."
  @spec title() :: String.t()
  def title, do: @title

  @doc """
  The five-second load: sleep in the calling process, then record one completed
  load run in the application service.

  The `busy` button runs exactly this function inside the view process;
  `LiveCimgui.Demo.busy/0` runs it in the caller (IEx) instead, because a native
  button click cannot be synthesized through the framework's test-input path.
  """
  @spec run_busy() :: :ok | {:error, State.error()}
  def run_busy do
    Process.sleep(@busy_ms)
    State.record_load_run()
  end

  @impl LiveCimgui.View
  def mount(params, _session, socket) do
    server = state_server(params)
    :ok = State.subscribe(server)

    socket =
      socket
      |> assign(:state_server, server)
      |> assign(:view_generation, PhoenixAdapter.private(socket, :live_cimgui_generation))
      # A restarted view replays the previous incarnation's checkpoint. The draft
      # and the last seen revision are view-local, so they survive a restart even
      # before the native host re-reports its drafts.
      |> assign(:draft, Map.get(socket.assigns, :draft, ""))
      |> assign(:last_ack_revision, Map.get(socket.assigns, :last_ack_revision, 0))
      |> assign(:notice, nil)
      |> refresh(State.snapshot(server))

    {:ok, socket}
  end

  @impl LiveCimgui.View
  def render(assigns) do
    column(
      [
        text(@title),
        input(@draft_id, assigns.draft, label: "draft"),
        keyed("rows", Enum.map(assigns.rows, &row_editor/1)),
        row([
          button("busy", "Busy Elixir for 5 seconds"),
          button("reverse", "Reverse keyed list"),
          button("add", "Add row"),
          button("remove", "Remove row"),
          button("restart-view", "Restart view process")
        ])
      ] ++ elixir_diagnostics(assigns) ++ [diagnostics()]
    )
  end

  @impl LiveCimgui.View
  def handle_event("busy", _params, socket), do: {:noreply, mutate(socket, run_busy())}

  def handle_event("reverse", _params, socket),
    do: {:noreply, mutate(socket, State.reverse_rows(state_server(socket)))}

  def handle_event("add", _params, socket),
    do: {:noreply, mutate(socket, State.add_row(state_server(socket)))}

  def handle_event("remove", _params, socket),
    do: {:noreply, mutate(socket, State.remove_row(state_server(socket)))}

  def handle_event("restart-view", _params, socket) do
    # Fault injection through the manager's control path: the manager kills this
    # process and starts a replacement generation, which is the only way a view
    # may be restarted. The kill happens inside this call, so the handler never
    # returns — which is exactly the interruption being demonstrated.
    :ok = HostManager.restart_view(manager(socket))
    {:noreply, socket}
  end

  def handle_event("window_close", _params, socket) do
    manager = manager(socket)

    # Closing the manager from inside this callback would tear it down while this
    # event's own render is still in flight. `LiveCimgui.Demo.stop/1` is the
    # documented close path, so run it a moment later, outside this process.
    _ =
      Task.start(fn ->
        Process.sleep(100)
        LiveCimgui.Demo.stop(manager)
      end)

    {:noreply, note(socket, "window closed; stopping the demo")}
  end

  def handle_event(@draft_id, params, socket) do
    {:noreply, edit_draft(socket, params)}
  end

  def handle_event(
        id,
        %{"value" => value, "incarnation" => incarnation, "draft_revision" => revision},
        socket
      ) do
    {:noreply, edit_row(socket, {id, incarnation, revision}, value)}
  end

  def handle_event(id, params, socket) do
    {:noreply, note(socket, "unhandled event #{inspect(id)}: #{short(params)}")}
  end

  @impl LiveCimgui.View
  def handle_info({:demo_state, snapshot}, socket) when is_map(snapshot) do
    {:noreply, refresh(socket, snapshot)}
  end

  def handle_info({:demo_state, :stopping}, socket) do
    # Documented shutdown path (see the module doc): the demo is being stopped,
    # so leave the subscriber list before the manager disappears.
    :ok = State.unsubscribe(state_server(socket))
    {:noreply, note(socket, "demo stopping; unsubscribed from the application service")}
  end

  def handle_info({:live_cimgui, :drafts, drafts}, socket) do
    {:noreply, fold_drafts(socket, drafts)}
  end

  def handle_info({:live_cimgui, :host_restarted, info}, socket) do
    {:noreply,
     note(
       socket,
       "native host restarted as generation #{Map.get(info, :host_generation, "?")} " <>
         "(#{short(Map.get(info, :reason))}); the window was rebuilt from the last description"
     )}
  end

  def handle_info({:live_cimgui, :host_unavailable, reason}, socket) do
    {:noreply,
     note(
       socket,
       "native host unavailable (#{short(reason)}); application state is intact and the " <>
         "manager keeps trying"
     )}
  end

  def handle_info({:live_cimgui, :overload, overload}, socket) do
    {:noreply, note(socket, "framework overload notice: #{short(overload)}")}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Rendering

  defp row_editor(%{key: key, incarnation: incarnation, text: text}) do
    {key, incarnation, input(key, text, label: key, incarnation: incarnation)}
  end

  defp elixir_diagnostics(assigns) do
    [
      text("view generation: #{assigns.view_generation}"),
      text("load runs completed: #{assigns.load_runs}"),
      text("last acknowledged draft revision: #{assigns.last_ack_revision}"),
      text(
        "application rows: #{length(assigns.rows)}/#{assigns.max_rows} (load-run bound: #{assigns.max_load_runs})"
      )
    ] ++ notice_lines(assigns.notice)
  end

  defp notice_lines(nil), do: []
  defp notice_lines(notice), do: [text("notice: #{notice}")]

  ## Events

  defp edit_draft(socket, params) do
    socket
    |> assign(:draft, Map.get(params, "value", socket.assigns.draft))
    |> track_revision(Map.get(params, "draft_revision"))
  end

  defp edit_row(socket, {id, incarnation, revision}, value) do
    socket = track_revision(socket, revision)

    case State.set_text(id, incarnation, value, state_server(socket)) do
      :ok ->
        note(socket, nil)

      {:error, reason} ->
        note(socket, "application refused #{inspect(id)} (incarnation #{incarnation}): #{reason}")
    end
  end

  defp mutate(socket, :ok), do: note(socket, nil)
  defp mutate(socket, {:ok, _row}), do: note(socket, nil)

  defp mutate(socket, {:error, reason}),
    do: note(socket, "application refused the change: #{reason}")

  ## Framework messages

  defp fold_drafts(socket, drafts) do
    case surviving_drafts(drafts) do
      [] ->
        socket

      surviving ->
        {socket, notes} =
          Enum.reduce(surviving, {socket, []}, fn draft, {socket, notes} ->
            {socket, note} = fold_draft(socket, draft)
            {socket, [note | notes]}
          end)

        note(
          socket,
          "#{length(surviving)} native draft(s) survived the view restart: " <>
            Enum.join(Enum.reverse(notes), "; ")
        )
    end
  end

  # The host reports every widget whenever it applies a description. A widget
  # whose native draft revision is not ahead of its acknowledged revision has
  # nothing to reconcile, so it is not a surviving draft.
  defp surviving_drafts(drafts) do
    Enum.filter(drafts, fn draft ->
      Map.get(draft, :draft_revision, 0) > Map.get(draft, :ack_revision, 0)
    end)
  end

  defp fold_draft(socket, %{id: @draft_id, text: text}),
    do: {assign(socket, :draft, text), "#{@draft_id} restored locally"}

  defp fold_draft(socket, %{id: id, incarnation: incarnation, text: text} = draft) do
    socket = track_revision(socket, Map.get(draft, :ack_revision))

    case State.set_text(id, incarnation, text, state_server(socket)) do
      :ok -> {socket, "#{id} folded into the application service"}
      {:error, reason} -> {socket, "#{id} not folded (#{reason})"}
    end
  end

  defp fold_draft(socket, draft), do: {socket, "unrecognized draft: #{short(draft)}"}

  ## Helpers

  defp refresh(socket, snapshot) do
    socket
    |> assign(:rows, snapshot.rows)
    |> assign(:load_runs, snapshot.load_runs)
    |> assign(:max_rows, snapshot.max_rows)
    |> assign(:max_load_runs, snapshot.max_load_runs)
  end

  defp track_revision(socket, revision) when is_integer(revision),
    do: assign(socket, :last_ack_revision, max(socket.assigns.last_ack_revision, revision))

  defp track_revision(socket, _revision), do: socket

  defp note(socket, notice) when is_binary(notice) or is_nil(notice),
    do: assign(socket, :notice, notice)

  # `mount/3` params are atom-keyed by convention: `LiveCimgui.Demo.start/1`
  # passes `%{state: server}`.
  defp state_server(params), do: Map.get(params, :state, State)

  defp manager(socket), do: PhoenixAdapter.private(socket, :manager)

  # Bounded rendering of arbitrary terms into a single text node.
  defp short(term), do: inspect(term, limit: 8, printable_limit: 256)
end
