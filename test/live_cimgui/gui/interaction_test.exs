defmodule LiveCimgui.Gui.InteractionView do
  @moduledoc false
  # View used by the interactive GUI acceptance tests. It reports what it
  # received to the test process so assertions can be made about both the Elixir
  # callbacks and the native window.

  use LiveCimgui.View
  import LiveCimgui.UI

  def mount(_params, session, socket) do
    {:ok,
     assign(socket,
       test_pid: Map.fetch!(session, :test_pid),
       rows: Map.fetch!(session, :rows),
       clicks: 0,
       draft: "draft",
       busy_ms: Map.get(session, :busy_ms, 5_000)
     )}
  end

  def render(assigns) do
    column([
      text("gui acceptance view"),
      row([
        button("a", "Button A"),
        button("b", "Button B"),
        button("busy", "Busy Elixir for 5 seconds"),
        button("reset", "Reset counter")
      ]),
      input("counter-view", "clicks=#{assigns.clicks}"),
      input("draft", assigns.draft, label: "draft:"),
      keyed(
        "rows",
        Enum.map(assigns.rows, fn row ->
          # The keyed child carries the row's incarnation, and so does the widget
          # itself: deleting a row and recreating the same key must produce a
          # *different* native editor, not a reused buffer.
          {row.key, row.incarnation,
           input("editor/" <> row.key, row.text, label: row.key, incarnation: row.incarnation)}
        end)
      ),
      diagnostics()
    ])
  end

  # A real view accepts the draft: it folds the text into its own presentation
  # state, so the next description carries the accepted text and the native
  # buffer is not rewritten behind the user's back.
  def handle_event(id, %{"action" => action, "value" => value} = params, socket)
      when action in ["edit", "submit"] do
    notify(socket, {:edit, id, params})
    {:noreply, accept_text(socket, id, value)}
  end

  def handle_event("a", params, socket) do
    notify(socket, {:button, "a", params})
    {:noreply, bump(socket, socket.assigns.clicks + 1)}
  end

  def handle_event("b", params, socket) do
    notify(socket, {:button, "b", params})
    {:noreply, bump(socket, socket.assigns.clicks + 2)}
  end

  def handle_event("reset", _params, socket), do: {:noreply, bump(socket, 0)}

  def handle_event("busy", _params, socket) do
    notify(socket, {:busy_start, socket.assigns.busy_ms})
    Process.sleep(socket.assigns.busy_ms)
    notify(socket, :busy_done)
    {:noreply, socket}
  end

  def handle_info({:rows, rows}, socket), do: {:noreply, assign(socket, :rows, rows)}

  # Reversing the view's *own* rows is what the demo's application service does;
  # it keeps the text each editor has already been acknowledged for.
  def handle_info(:reverse, socket),
    do: {:noreply, assign(socket, :rows, Enum.reverse(socket.assigns.rows))}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp bump(socket, clicks), do: assign(socket, :clicks, clicks)

  # The draft editor keeps its text in `draft`; a row editor keeps it in the row
  # with that key. Text the view does not know about (a key that was removed
  # while the edit was in flight) is dropped, which is a rejected draft.
  defp accept_text(socket, "draft", value), do: assign(socket, :draft, value)

  defp accept_text(socket, "editor/" <> key, value) do
    rows =
      Enum.map(socket.assigns.rows, fn
        %{key: ^key} = row -> %{row | text: value}
        row -> row
      end)

    assign(socket, :rows, rows)
  end

  defp accept_text(socket, _other_id, _value), do: socket

  defp notify(socket, message) do
    send(socket.assigns.test_pid, {:view, message})
    socket
  end
end

defmodule LiveCimgui.Gui.InteractionTest do
  @moduledoc """
  Interactive GUI acceptance tests: they click and type into a real Dear ImGui
  window and assert on both the Elixir callbacks and the native widget state.

  Input is injected through `LiveCimgui.HostManager.inject/2`, which feeds Dear
  ImGui's own input queue — the same code path real typing and clicking take
  (ImGui input handling, the widget's text state, our edit callback). This
  environment (WSLg, no window manager) cannot give the window keyboard focus, so
  server-level input injection such as xdotool is recorded as a *manual* check in
  `docs/TESTING.md` instead.
  """

  use ExUnit.Case, async: false

  import LiveCimgui.GuiHarness

  alias LiveCimgui.HostManager

  @moduletag :gui
  @moduletag timeout: 180_000

  defp start_view(rows, opts \\ []) do
    # Managers are started under the application's host supervisor, exactly like
    # production use: a manager started with `start_link` from an ephemeral
    # process would be terminated by OTP when that process (the test) goes away.
    child =
      {HostManager,
       [
         view: LiveCimgui.Gui.InteractionView,
         params: %{},
         session: %{test_pid: self(), rows: rows},
         title: "live_cimgui gui acceptance",
         restart_limit: Keyword.get(opts, :restart_limit, 3),
         restart_window_ms: Keyword.get(opts, :restart_window_ms, 5_000)
       ]}

    {:ok, manager} = DynamicSupervisor.start_child(LiveCimgui.HostSupervisor, child)

    on_exit(fn ->
      if Process.alive?(manager), do: HostManager.close(manager)
    end)

    wait_until(fn -> HostManager.status(manager).ready end, "the native host never became ready")
    wait_until(fn -> HostManager.status(manager).view_pid != nil end, "the view never started")
    settle(manager)
    manager
  end

  defp rows do
    [
      %{key: "alpha", incarnation: 1, text: "Alpha"},
      %{key: "bravo", incarnation: 1, text: "Bravo"},
      %{key: "charlie", incarnation: 1, text: "Charlie"}
    ]
  end

  test "case 1a: a native button event reaches handle_event/3" do
    manager = start_view(rows())

    click!(manager, "a")

    assert_receive {:view, {:button, "a", params}}, 5_000
    assert params["id"] == "a"
    assert params["incarnation"] == 1
    assert params["event"] == "a"
  end

  test "case 1 (window side): clicking a button changes an assign that the window then displays" do
    manager = start_view(rows())

    assert widget!(manager, "counter-view").text == "clicks=0"
    revision_before = HostManager.status(manager).ui_revision

    click!(manager, "a")
    wait_for_widget_text(manager, "counter-view", "clicks=1")
    assert HostManager.status(manager).ui_revision > revision_before

    click!(manager, "b")
    wait_for_widget_text(manager, "counter-view", "clicks=3")
  end

  test "case 2: native input and frame progress continue during a five-second callback" do
    manager = start_view(rows(), busy_ms: 5_000)

    frames_before = inspect_host!(manager).frame_count
    click!(manager, "a")
    wait_for_widget_text(manager, "counter-view", "clicks=1")

    start = System.monotonic_time(:millisecond)
    click!(manager, "busy", settle: false)
    assert_receive {:view, {:busy_start, 5_000}}, 2_000

    # The native window keeps rendering while the view is stalled.
    wait_for_frames(manager, frames_before + 20)
    frames_during_stall = inspect_host!(manager).frame_count
    assert frames_during_stall > frames_before

    # ... and native input still produces drafts with increasing revisions: focus
    # the editor *while* the view is blocked (clicking a button clears focus), then
    # type into it. The view cannot answer yet, so nothing here waits for it to
    # settle.
    click!(manager, "draft", settle: false)
    type!(manager, "-during-stall", settle: false)
    wait_for_widget_text_contains(manager, "draft", "-during-stall")
    draft_during_stall = widget!(manager, "draft")
    assert draft_during_stall.draft_revision >= 1
    assert draft_during_stall.ack_revision < draft_during_stall.draft_revision

    assert_receive {:view, :busy_done}, 15_000
    elapsed = System.monotonic_time(:millisecond) - start
    assert elapsed >= 4_500, "the busy callback returned too early (#{elapsed} ms)"

    # Only after the callback finished does Elixir accept and acknowledge the draft.
    assert_receive {:view, {:edit, "draft", %{"draft_revision" => revision, "value" => value}}},
                   10_000

    assert revision == draft_during_stall.draft_revision
    assert String.contains?(value, "-during-stall")

    wait_until(
      fn ->
        widget = widget!(manager, "draft")
        widget.ack_revision >= revision and widget.ack_revision > 0
      end,
      "the draft was never acknowledged"
    )

    final = widget!(manager, "draft")
    assert final.text == draft_during_stall.text
    assert final.ack_revision >= revision
  end

  test "case 3: a keyed reorder preserves the editor's text, caret, and selection" do
    manager = start_view(rows())

    # Focus two different editors, type into each, then place the caret and make a
    # selection with real pointer input in the one we will track across the
    # reorder. The last row is the interesting one: after reversing, it must be
    # first, and it must still be the same editor.
    click!(manager, "editor/bravo")
    type!(manager, "-B")
    click!(manager, "editor/charlie")
    type!(manager, "-C")
    settle(manager)

    {x, y} = rect_center!(manager, "editor/charlie")
    drag!(manager, {x - 30, y}, {x + 20, y})
    settle(manager)

    before = widget!(manager, "editor/charlie")
    assert String.contains?(before.text, "-C")
    assert before.selection != {0, 0}

    order_before = editor_order(manager)
    assert Enum.sort(order_before) == ["editor/alpha", "editor/bravo", "editor/charlie"]
    assert List.last(order_before) == "editor/charlie"

    # Reverse the keyed collection through the view: a fresh description with the
    # same keys and incarnations in the opposite order.
    send(HostManager.status(manager).view_pid, :reverse)

    wait_until(
      fn -> editor_order(manager) == Enum.reverse(order_before) end,
      "the row editors were never reordered (saw #{inspect(editor_order(manager))})"
    )

    order_after = editor_order(manager)
    assert order_after == Enum.reverse(order_before)
    assert List.first(order_after) == "editor/charlie"

    # The editor moved to a different row, and its native state followed the key:
    # text, caret, and selection are exactly what they were.
    after_reorder = widget!(manager, "editor/charlie")
    assert after_reorder.incarnation == before.incarnation
    assert after_reorder.text == before.text
    assert after_reorder.cursor == before.cursor
    assert after_reorder.selection == before.selection

    # The other editor kept its state too, and no editor inherited text.
    assert String.contains?(widget!(manager, "editor/bravo").text, "-B")
    assert widget!(manager, "editor/alpha").text == "Alpha"
  end

  test "case 4: a delayed acknowledgement cannot overwrite newer native text" do
    manager = start_view(rows())

    click!(manager, "editor/alpha")
    type!(manager, "-1")
    settle(manager)

    first = widget!(manager, "editor/alpha")
    assert first.draft_revision >= 1
    assert first.ack_revision >= first.draft_revision

    type!(manager, "-2")
    settle(manager)
    second = widget!(manager, "editor/alpha")
    assert second.draft_revision > first.draft_revision
    assert second.ack_revision >= second.draft_revision

    # A delayed acknowledgement for an older revision must not move state back.
    status = HostManager.status(manager)

    :ok =
      HostManager.acknowledge(
        manager,
        status.view_generation,
        "editor/alpha",
        second.incarnation,
        first.draft_revision
      )

    after_delayed_ack = widget!(manager, "editor/alpha")
    assert after_delayed_ack.ack_revision == second.ack_revision
    assert after_delayed_ack.text == second.text
    assert after_delayed_ack.draft_revision >= second.draft_revision
  end

  test "case 4b: a deleted editor rejects updates for its previous incarnation" do
    manager = start_view(rows())

    click!(manager, "editor/alpha")
    type!(manager, "-old")
    settle(manager)
    old = widget!(manager, "editor/alpha")
    assert String.contains?(old.text, "-old")

    without_alpha = Enum.reject(rows(), &(&1.key == "alpha"))
    send(HostManager.status(manager).view_pid, {:rows, without_alpha})

    wait_until(
      fn -> Enum.all?(inspect_host!(manager).widgets, &(&1.id != "editor/alpha")) end,
      "the deleted editor stayed in the native widget set"
    )

    # Recreate the same key with a new incarnation: it must not inherit the
    # previous editor's buffer.
    recreated = [%{key: "alpha", incarnation: 2, text: "Alpha v2"}] ++ without_alpha
    send(HostManager.status(manager).view_pid, {:rows, recreated})

    fresh =
      wait_until(
        fn ->
          case Enum.find(inspect_host!(manager).widgets, &(&1.id == "editor/alpha")) do
            %{incarnation: 2} = widget -> widget
            _other -> nil
          end
        end,
        "the recreated editor never appeared"
      )

    assert fresh.text == "Alpha v2"

    status = HostManager.status(manager)

    :ok =
      HostManager.set_value(
        manager,
        status.view_generation,
        "editor/alpha",
        1,
        "STALE-PREVIOUS-INCARNATION",
        0
      )

    Process.sleep(150)

    after_stale_update = widget!(manager, "editor/alpha")
    assert after_stale_update.incarnation == 2
    assert after_stale_update.text == "Alpha v2"
  end
end
