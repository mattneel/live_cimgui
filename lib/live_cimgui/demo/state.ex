defmodule LiveCimgui.Demo.State do
  @initial_rows [
    %{key: "alpha", incarnation: 1, text: "Alpha"},
    %{key: "bravo", incarnation: 1, text: "Bravo"},
    %{key: "charlie", incarnation: 1, text: "Charlie"}
  ]

  @max_rows 16
  @max_load_runs 1_000
  @max_text_bytes 256

  @moduledoc """
  The demo application service: durable application state for the demo window.

  `LiveCimgui.Demo.View` subscribes here, mirrors every broadcast into its
  assigns, and sends every mutation back. Nothing in this module knows about
  rendering, the view process, or the native host. That is what makes the window
  survive a view restart or a native host crash with the application state
  intact: killing the view or the host never touches this process.

  ## Rows, keys, and incarnations

  A row is `%{key: String.t(), incarnation: pos_integer(), text: String.t()}`.
  The `key` is the row's identity in the native description — the view uses it
  as the widget id — so it is never derived from position. The `incarnation` is
  the other half of that identity and is issued here:

    * the initial rows are `alpha`/`Alpha`, `bravo`/`Bravo`, `charlie`/`Charlie`,
      all with incarnation 1;
    * `add_row/1` allocates the smallest `n` whose key `"row-n"` is not currently
      in use, and gives the row the text `"Row n"`. A key removed by
      `remove_row/1` can therefore be reused by the next `add_row/1`;
    * every incarnation ever issued for a key is remembered, so a recreated key
      always receives a strictly greater incarnation than any previous row with
      that key. A recreated native editor can never inherit the deleted editor's
      text, caret, selection, or draft.

  ## Bounds

  Row count and completed load runs are bounded per instance by `:max_rows`
  (default #{@max_rows}) and `:max_load_runs` (default #{@max_load_runs});
  `set_text/4` bounds text at #{@max_text_bytes} bytes. A mutation that would exceed a bound
  returns `{:error, :full}` and leaves the state untouched: the bound is never
  worked around by silently truncating a list.

  ## Broadcasting

  Every successful mutation sends `{:demo_state, snapshot}` to every subscriber
  with `send/2` — there is no PubSub dependency. A mutation rejected because it
  hit a bound (`{:error, :full}`) also broadcasts, so subscribers see that the
  state is unchanged rather than silently truncated. Rejections that cannot
  change state (`:stale_incarnation`, `:not_found`, `:too_long`,
  `:invalid_text`, `:empty`) do not broadcast, and neither does a `set_text/4`
  whose normalized text equals the stored text: folding an already-applied
  native draft back into the application service is idempotent, returns `:ok`,
  and produces no broadcast (and therefore no render).

  Subscribers are plain pids and are pruned when no longer alive on every
  broadcast, so a killed view process cannot make the fan-out grow without
  bound.

  ## Instances

  `LiveCimgui.Application` starts one instance registered as
  `#{inspect(__MODULE__)}`; the default arguments below address that instance.
  Tests and multiple windows can start their own instances and pass the pid or
  name explicitly — the last argument everywhere:

      LiveCimgui.Demo.State.set_text("alpha", 1, "  renamed  ", my_state)
  """

  use GenServer

  @typedoc "One application row: identity, incarnation, and normalized text."
  @type row :: %{key: String.t(), incarnation: pos_integer(), text: String.t()}

  @typedoc "What `snapshot/1` returns and subscribers receive."
  @type snapshot :: %{
          rows: [row()],
          load_runs: non_neg_integer(),
          max_rows: pos_integer(),
          max_load_runs: pos_integer()
        }

  @typedoc "Rejection reason for a mutation."
  @type error :: :full | :empty | :not_found | :stale_incarnation | :too_long | :invalid_text

  defstruct rows: @initial_rows,
            incarnations: Map.new(@initial_rows, &{&1.key, &1.incarnation}),
            load_runs: 0,
            subscribers: [],
            max_rows: @max_rows,
            max_load_runs: @max_load_runs

  @doc """
  Starts an application service instance.

  Options:

    * `:name` — registered name; defaults to `#{inspect(__MODULE__)}`, pass `nil`
      for an unregistered instance;
    * `:max_rows` — row-count bound (default #{@max_rows});
    * `:max_load_runs` — completed-load-run bound (default #{@max_load_runs}).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Subscribes the calling process to snapshot broadcasts.

      LiveCimgui.Demo.State.subscribe()

  Idempotent per pid: subscribing twice delivers one message per mutation.
  """
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ __MODULE__), do: GenServer.call(server, {:subscribe, self()})

  @doc """
  Removes the calling process from the subscriber list.

      LiveCimgui.Demo.State.unsubscribe()
  """
  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(server \\ __MODULE__), do: GenServer.call(server, {:unsubscribe, self()})

  @doc """
  The complete application state, exactly as broadcast.

      %{rows: rows, load_runs: runs, max_rows: max_rows, max_load_runs: max_load_runs} =
        LiveCimgui.Demo.State.snapshot()
  """
  @spec snapshot(GenServer.server()) :: snapshot()
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @doc """
  The rows in application order.

      LiveCimgui.Demo.State.rows()
  """
  @spec rows(GenServer.server()) :: [row()]
  def rows(server \\ __MODULE__), do: GenServer.call(server, :rows)

  @doc """
  How many load runs have completed.

      LiveCimgui.Demo.State.load_runs()
  """
  @spec load_runs(GenServer.server()) :: non_neg_integer()
  def load_runs(server \\ __MODULE__), do: GenServer.call(server, :load_runs)

  @doc """
  Appends a row: the smallest unused `"row-n"` key, the text `"Row n"`, and an
  incarnation greater than any previously issued for that key.

      {:ok, %{key: "row-1", incarnation: 1, text: "Row 1"}} = LiveCimgui.Demo.State.add_row()

  Returns `{:error, :full}` when the row bound is already reached.
  """
  @spec add_row(GenServer.server()) :: {:ok, row()} | {:error, error()}
  def add_row(server \\ __MODULE__), do: GenServer.call(server, :add_row)

  @doc """
  Removes the last row in application order and returns it.

      {:ok, %{key: "row-1"}} = LiveCimgui.Demo.State.remove_row()

  Returns `{:error, :empty}` when there is nothing to remove.
  """
  @spec remove_row(GenServer.server()) :: {:ok, row()} | {:error, error()}
  def remove_row(server \\ __MODULE__), do: GenServer.call(server, :remove_row)

  @doc """
  Reverses application order. Keys and incarnations move with their rows, so no
  native widget identity changes and no editor state moves between rows.

      :ok = LiveCimgui.Demo.State.reverse_rows()
  """
  @spec reverse_rows(GenServer.server()) :: :ok
  def reverse_rows(server \\ __MODULE__), do: GenServer.call(server, :reverse_rows)

  @doc """
  Replaces one row's text, addressed by `{key, incarnation}`.

  The text is normalized first (`normalize/1`). A key that no longer exists
  returns `{:error, :not_found}`; a key whose current incarnation differs from
  `incarnation` — the row was deleted and recreated — returns
  `{:error, :stale_incarnation}` and the row is left untouched. Both refusals are
  ordinary return values, so a view can report them without crashing.

      :ok = LiveCimgui.Demo.State.set_text("alpha", 1, "  renamed  ", state)

  The trailing `state` is the instance; the three-argument form addresses the
  application instance registered as `#{inspect(__MODULE__)}`.
  """
  @spec set_text(String.t(), pos_integer(), String.t(), GenServer.server()) ::
          :ok | {:error, error()}
  def set_text(key, incarnation, text, server \\ __MODULE__),
    do: GenServer.call(server, {:set_text, key, incarnation, text})

  @doc """
  Records one completed load run.

      :ok = LiveCimgui.Demo.State.record_load_run()

  Returns `{:error, :full}` at the load-run bound.
  """
  @spec record_load_run(GenServer.server()) :: :ok | {:error, error()}
  def record_load_run(server \\ __MODULE__), do: GenServer.call(server, :record_load_run)

  @doc """
  The documented application normalization: collapse every run of whitespace to
  a single space and trim both ends. Applied by `set_text/4`, so a native draft
  arrives in application state already normalized.

      LiveCimgui.Demo.State.normalize("  two \\n  words  ")
      #=> "two words"
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(text) when is_binary(text) do
    text |> String.split(~r/\s+/u, trim: true) |> Enum.join(" ")
  end

  @impl GenServer
  def init(opts) do
    state = %__MODULE__{
      max_rows: Keyword.get(opts, :max_rows, @max_rows),
      max_load_runs: Keyword.get(opts, :max_load_runs, @max_load_runs)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:subscribe, pid}, _from, state) when is_pid(pid) do
    {:reply, :ok, %{state | subscribers: Enum.uniq([pid | state.subscribers])}}
  end

  def handle_call({:unsubscribe, pid}, _from, state) when is_pid(pid) do
    {:reply, :ok, %{state | subscribers: List.delete(state.subscribers, pid)}}
  end

  def handle_call(:snapshot, _from, state), do: {:reply, state_snapshot(state), state}
  def handle_call(:rows, _from, state), do: {:reply, state.rows, state}
  def handle_call(:load_runs, _from, state), do: {:reply, state.load_runs, state}

  def handle_call(:add_row, _from, %__MODULE__{rows: rows, max_rows: max} = state)
      when length(rows) >= max,
      do: {:reply, {:error, :full}, broadcast(state)}

  def handle_call(:add_row, _from, state) do
    {key, number} = next_key(state)
    incarnation = Map.get(state.incarnations, key, 0) + 1
    row = %{key: key, incarnation: incarnation, text: "Row #{number}"}

    state = %{
      state
      | rows: state.rows ++ [row],
        incarnations: Map.put(state.incarnations, key, incarnation)
    }

    {:reply, {:ok, row}, broadcast(state)}
  end

  def handle_call(:remove_row, _from, %__MODULE__{rows: []} = state),
    do: {:reply, {:error, :empty}, state}

  def handle_call(:remove_row, _from, state) do
    {removed, rows} = List.pop_at(state.rows, -1)
    {:reply, {:ok, removed}, broadcast(%{state | rows: rows})}
  end

  def handle_call(:reverse_rows, _from, state),
    do: {:reply, :ok, broadcast(%{state | rows: Enum.reverse(state.rows)})}

  def handle_call({:set_text, key, incarnation, text}, _from, state) do
    case apply_text(state, key, incarnation, text) do
      :unchanged -> {:reply, :ok, state}
      {:ok, state} -> {:reply, :ok, broadcast(state)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        :record_load_run,
        _from,
        %__MODULE__{load_runs: runs, max_load_runs: max} = state
      )
      when runs >= max,
      do: {:reply, {:error, :full}, broadcast(state)}

  def handle_call(:record_load_run, _from, state),
    do: {:reply, :ok, broadcast(%{state | load_runs: state.load_runs + 1})}

  # The next key is the smallest number whose key is unused. Because a row set of
  # n entries can occupy at most n of the first n + 1 numbers, the search bound is
  # exact and does not grow with the number of rows ever created.
  defp next_key(state) do
    taken = MapSet.new(state.rows, & &1.key)

    number =
      Enum.find(1..(length(state.rows) + 1), fn n -> not MapSet.member?(taken, "row-#{n}") end)

    {"row-#{number}", number}
  end

  defp apply_text(state, key, incarnation, text) do
    with {:ok, row} <- fetch_row(state, key, incarnation),
         :ok <- check_text(text) do
      normalized = normalize(text)

      if normalized == row.text do
        :unchanged
      else
        {:ok, %{state | rows: Enum.map(state.rows, &put_text(&1, {key, normalized}))}}
      end
    end
  end

  defp fetch_row(state, key, incarnation) do
    case Enum.find(state.rows, &(&1.key == key)) do
      nil -> {:error, :not_found}
      %{incarnation: ^incarnation} = row -> {:ok, row}
      %{} -> {:error, :stale_incarnation}
    end
  end

  defp check_text(text) when is_binary(text) and byte_size(text) > @max_text_bytes,
    do: {:error, :too_long}

  defp check_text(text) when is_binary(text), do: :ok
  defp check_text(_text), do: {:error, :invalid_text}

  # The row whose key matches gets the normalized text; every other row (and the
  # identity check itself) is matched in the head, not in a conditional.
  defp put_text(%{key: key} = row, {key, text}), do: %{row | text: text}
  defp put_text(row, _target), do: row

  defp state_snapshot(state) do
    %{
      rows: state.rows,
      load_runs: state.load_runs,
      max_rows: state.max_rows,
      max_load_runs: state.max_load_runs
    }
  end

  defp broadcast(state) do
    subscribers = Enum.filter(state.subscribers, &Process.alive?/1)
    message = {:demo_state, state_snapshot(state)}
    Enum.each(subscribers, &send(&1, message))
    %{state | subscribers: subscribers}
  end
end
