defmodule LiveCimgui.Demo.StateTest do
  use ExUnit.Case, async: true

  alias LiveCimgui.Demo.State

  defp start_state(opts \\ []) do
    start_supervised!({State, Keyword.put_new(opts, :name, nil)})
  end

  test "starts with the three documented rows" do
    state = start_state()

    assert State.rows(state) == [
             %{key: "alpha", incarnation: 1, text: "Alpha"},
             %{key: "bravo", incarnation: 1, text: "Bravo"},
             %{key: "charlie", incarnation: 1, text: "Charlie"}
           ]

    assert State.load_runs(state) == 0

    assert %{
             rows: [_, _, _] = rows,
             load_runs: 0,
             max_rows: 16,
             max_load_runs: 1_000
           } = State.snapshot(state)

    assert Enum.map(rows, & &1.key) == ["alpha", "bravo", "charlie"]
  end

  test "the application supervision tree starts the default instance" do
    assert %{rows: rows, load_runs: 0} = State.snapshot()
    assert Enum.map(rows, & &1.key) == ["alpha", "bravo", "charlie"]
  end

  test "add_row appends \"Row n\" with a key-derived identity" do
    state = start_state()

    assert {:ok, %{key: "row-1", incarnation: 1, text: "Row 1"}} = State.add_row(state)
    assert {:ok, %{key: "row-2", incarnation: 1, text: "Row 2"}} = State.add_row(state)

    assert Enum.map(State.rows(state), & &1.key) ==
             ["alpha", "bravo", "charlie", "row-1", "row-2"]
  end

  test "remove_row removes the last row; reverse_rows reverses application order" do
    state = start_state()

    assert {:ok, %{key: "charlie", incarnation: 1}} = State.remove_row(state)
    assert :ok = State.reverse_rows(state)
    assert Enum.map(State.rows(state), & &1.key) == ["bravo", "alpha"]

    assert {:ok, %{key: "alpha"}} = State.remove_row(state)
    assert {:ok, %{key: "bravo"}} = State.remove_row(state)
    assert {:error, :empty} = State.remove_row(state)
    assert State.rows(state) == []
  end

  test "a removed key is reused by the next add_row with a strictly greater incarnation" do
    state = start_state()

    assert {:ok, %{key: "row-1", incarnation: 1}} = State.add_row(state)
    assert {:ok, %{key: "row-1", incarnation: 1}} = State.remove_row(state)

    assert {:ok, %{key: "row-1", incarnation: 2, text: "Row 1"}} = State.add_row(state)
    assert {:ok, %{key: "row-1", incarnation: 2}} = State.remove_row(state)

    assert {:ok, %{key: "row-1", incarnation: 3}} = State.add_row(state)
  end

  test "set_text normalizes whitespace runs and trims the ends" do
    state = start_state()

    assert :ok = State.set_text("alpha", 1, "  Hello   \n\t world  ", state)
    assert [%{key: "alpha", text: "Hello world"} | _rest] = State.rows(state)

    assert :ok = State.set_text("alpha", 1, " \n  ", state)
    assert [%{key: "alpha", text: ""} | _rest] = State.rows(state)

    assert State.normalize("one\ntwo  three") == "one two three"
  end

  test "set_text rejects a stale incarnation and leaves the row untouched" do
    state = start_state()

    assert {:ok, %{key: "row-1", incarnation: 1}} = State.add_row(state)
    assert {:ok, %{key: "row-1", incarnation: 1}} = State.remove_row(state)
    assert {:ok, %{key: "row-1", incarnation: 2}} = State.add_row(state)

    assert {:error, :stale_incarnation} = State.set_text("row-1", 1, "rejected", state)

    assert %{key: "row-1", incarnation: 2, text: "Row 1"} =
             Enum.find(State.rows(state), &(&1.key == "row-1"))

    assert {:error, :not_found} = State.set_text("never-created", 1, "rejected", state)
  end

  test "set_text rejects text beyond the documented bound" do
    state = start_state()

    assert {:error, :too_long} = State.set_text("alpha", 1, String.duplicate("x", 1_000), state)
    assert [%{key: "alpha", text: "Alpha"} | _rest] = State.rows(state)
  end

  test "record_load_run counts runs up to the documented bound" do
    state = start_state(max_load_runs: 2)

    assert :ok = State.record_load_run(state)
    assert :ok = State.record_load_run(state)
    assert State.load_runs(state) == 2

    assert {:error, :full} = State.record_load_run(state)
    assert State.load_runs(state) == 2
  end

  test "row mutations beyond max_rows return {:error, :full} without truncating" do
    state = start_state(max_rows: 3)

    assert {:error, :full} = State.add_row(state)
    assert Enum.map(State.rows(state), & &1.key) == ["alpha", "bravo", "charlie"]

    roomy = start_supervised!({State, [name: nil, max_rows: 4]}, id: :roomy_state)
    assert {:ok, %{key: "row-1"}} = State.add_row(roomy)
    assert {:error, :full} = State.add_row(roomy)
    assert Enum.map(State.rows(roomy), & &1.key) == ["alpha", "bravo", "charlie", "row-1"]
  end

  test "every successful mutation broadcasts the snapshot to subscribers" do
    state = start_state()
    assert :ok = State.subscribe(state)

    assert {:ok, %{key: "row-1"}} = State.add_row(state)

    assert_receive {:demo_state, %{rows: rows, load_runs: 0} = snapshot}
    assert Enum.map(rows, & &1.key) == ["alpha", "bravo", "charlie", "row-1"]
    assert snapshot.max_rows == 16

    assert :ok = State.record_load_run(state)
    assert_receive {:demo_state, %{load_runs: 1}}

    assert :ok = State.unsubscribe(state)
    assert :ok = State.reverse_rows(state)
    refute_receive {:demo_state, _snapshot}, 50
  end

  test "a mutation rejected by a bound is still broadcast, unchanged" do
    state = start_state(max_rows: 3)
    assert :ok = State.subscribe(state)

    assert {:error, :full} = State.add_row(state)
    assert_receive {:demo_state, %{rows: rows, max_rows: 3}}
    assert Enum.map(rows, & &1.key) == ["alpha", "bravo", "charlie"]

    assert :ok = State.unsubscribe(state)
  end

  test "set_text that changes nothing is a no-op and does not broadcast" do
    state = start_state()
    assert :ok = State.subscribe(state)

    assert :ok = State.set_text("alpha", 1, "  Alpha  ", state)
    assert [%{key: "alpha", text: "Alpha"} | _rest] = State.rows(state)
    refute_receive {:demo_state, _snapshot}, 50

    assert :ok = State.unsubscribe(state)
  end

  test "a stale draft is not broadcast and subscribers can be re-subscribed" do
    state = start_state()
    assert :ok = State.subscribe(state)
    assert :ok = State.subscribe(state)

    assert {:error, :stale_incarnation} = State.set_text("alpha", 99, "stale", state)
    refute_receive {:demo_state, _snapshot}, 50

    assert :ok = State.unsubscribe(state)
    assert :ok = State.unsubscribe(state)
    assert :ok = State.record_load_run(state)
    refute_receive {:demo_state, _snapshot}, 50
  end
end
