defmodule LiveCimgui.UI do
  @moduledoc """
  Typed constructors for the native render target.

  A `LiveCimgui.View`'s `render/1` returns exactly one node built with these
  functions. The vocabulary is intentionally closed — text, button, single-line
  text input, row, column, keyed child collections, and host diagnostics:

      import LiveCimgui.UI

      column([
        text("live_cimgui — Native interaction. Elixir application state."),
        input("draft", assigns.draft),
        row([
          button("busy", "Busy Elixir for 5 seconds"),
          button("reverse", "Reverse keyed list"),
          button("add", "Add row"),
          button("remove", "Remove row"),
          button("restart-view", "Restart view")
        ]),
        keyed("rows", Enum.map(assigns.rows, &{&1.key, &1.incarnation, input("editor/" <> &1.key, &1.text)})),
        diagnostics()
      ])

  ## Identity

  Interactive nodes (`button/3`, `input/3`) carry an explicit `id` and an
  `incarnation`. The pair `{id, incarnation}` is the native widget's identity:

    * the `id` must be derived from application keys, never from row position or
      a mutable label, so a reorder keeps the widget's text, caret, and
      selection;
    * the `incarnation` must be incremented by the application when a widget is
      deleted and later recreated under the same `id`, so native state from the
      previous incarnation can never be applied to the new one.

  Widget ids must be unique across the whole description; keyed children must
  have unique keys inside their collection. `validate/1` enforces both before a
  description reaches the native host.
  """

  alias LiveCimgui.Protocol
  alias LiveCimgui.UI.Error
  alias LiveCimgui.UI.Node

  @widget_kinds [:button, :input]
  @container_kinds [:row, :column]
  @all_kinds [:text, :button, :input, :row, :column, :keyed, :diagnostics]

  @doc "A line of static text."
  @spec text(String.t()) :: Node.t()
  def text(content) when is_binary(content), do: %Node{kind: :text, text: content}

  def text(other),
    do: raise(Error, reason: "text content must be a string, got #{inspect(other)}")

  @doc """
  A button.

  `event` defaults to the widget id and is what `handle_event/3` receives as the
  event name.
  """
  @spec button(String.t(), String.t(), keyword()) :: Node.t()
  def button(id, label, opts \\ []) when is_binary(id) and is_binary(label) do
    %Node{
      kind: :button,
      id: id,
      label: label,
      event: Keyword.get(opts, :event, id),
      incarnation: Keyword.get(opts, :incarnation, 1)
    }
  end

  @doc """
  A single-line text input.

  `value` is the application's view of the text. The native host keeps its own
  draft of an in-progress edit and only replaces it with `value` according to
  the conflict policy in `docs/PROTOCOL.md`.
  """
  @spec input(String.t(), String.t(), keyword()) :: Node.t()
  def input(id, value, opts \\ []) when is_binary(id) and is_binary(value) do
    %Node{
      kind: :input,
      id: id,
      value: value,
      label: Keyword.get(opts, :label, ""),
      incarnation: Keyword.get(opts, :incarnation, 1)
    }
  end

  @doc "A horizontal group of children."
  @spec row([Node.t()]) :: Node.t()
  def row(children) when is_list(children), do: %Node{kind: :row, children: children}
  def row(other), do: raise(Error, reason: "row children must be a list, got #{inspect(other)}")

  @doc "A vertical group of children."
  @spec column([Node.t()]) :: Node.t()
  def column(children) when is_list(children), do: %Node{kind: :column, children: children}

  def column(other),
    do: raise(Error, reason: "column children must be a list, got #{inspect(other)}")

  @doc """
  A keyed child collection.

  `children` is a list of `{key, node}` or `{key, incarnation, node}`. Keys are
  part of every descendant's native path, which is how identity survives a
  reorder. The `incarnation` of a keyed entry scopes native state that belongs
  to the collection itself (for example a row-level buffer) and must be
  incremented when the application deletes and recreates the same key.
  """
  @spec keyed(String.t(), [{String.t(), Node.t()} | {String.t(), pos_integer(), Node.t()}]) ::
          Node.t()
  def keyed(key, children) when is_binary(key) and is_list(children) do
    %Node{kind: :keyed, key: key, children: Enum.map(children, &keyed_child/1)}
  end

  def keyed(key, other) when is_binary(key),
    do:
      raise(Error, reason: "keyed #{inspect(key)} children must be a list, got #{inspect(other)}")

  def keyed(key, children) when is_list(children),
    do: raise(Error, reason: "keyed collection key must be a string, got #{inspect(key)}")

  def keyed(key, children),
    do:
      raise(Error,
        reason: "keyed(#{inspect(key)}, #{inspect(children)}) is not a valid keyed collection"
      )

  @doc """
  Host-owned live diagnostics.

  Renders counters read directly from native state on every frame: frame
  progress, the applied UI revision, per-editor draft and acknowledged
  revisions, and queue pressure. Nothing here is supplied by Elixir, so the
  values stay truthful while an Elixir callback is stalled.
  """
  @spec diagnostics() :: Node.t()
  def diagnostics, do: %Node{kind: :diagnostics}

  defp keyed_child({key, node}) when is_binary(key), do: {key, 1, node}
  defp keyed_child({key, incarnation, node}) when is_binary(key), do: {key, incarnation, node}

  defp keyed_child(other),
    do:
      raise(Error,
        reason:
          "keyed child must be {key, node} or {key, incarnation, node}, got #{inspect(other)}"
      )

  @doc """
  Validates a complete description.

  Returns the node unchanged when valid, otherwise `{:error, %LiveCimgui.UI.Error{}}`.
  Validation is total: kind, properties, string lengths, child counts, tree
  depth, node count, key uniqueness, and widget-id uniqueness are all checked
  before any part of the description reaches the native host.
  """
  @spec validate(term()) :: {:ok, Node.t()} | {:error, Error.t()}
  def validate(node) do
    case walk(node, "<root>", 1, %{count: 0, ids: %{}}) do
      {:ok, _state} -> {:ok, node}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @doc "Validates a complete description, raising `LiveCimgui.UI.Error` when invalid."
  @spec validate!(term()) :: Node.t()
  def validate!(node) do
    case validate(node) do
      {:ok, node} -> node
      {:error, error} -> raise error
    end
  end

  @doc """
  Every widget `{id, incarnation}` in a validated description, in render order.

  Used by tests and by the host manager to reconcile native drafts and
  acknowledgements after a view restart.
  """
  @spec widgets(Node.t()) :: [{String.t(), pos_integer()}]
  def widgets(node) do
    node
    |> collect_widgets([])
    |> Enum.reverse()
  end

  defp collect_widgets(%Node{kind: kind} = node, acc) when kind in @widget_kinds,
    do: [{node.id, node.incarnation} | acc]

  defp collect_widgets(%Node{kind: :keyed, children: children}, acc) do
    Enum.reduce(children, acc, fn {_key, _incarnation, child}, inner ->
      collect_widgets(child, inner)
    end)
  end

  defp collect_widgets(%Node{children: children}, acc) when is_list(children),
    do: Enum.reduce(children, acc, &collect_widgets/2)

  defp collect_widgets(_node, acc), do: acc

  defp walk(%Node{kind: kind} = node, path, depth, state) do
    cond do
      kind not in @all_kinds ->
        error("unsupported native kind #{inspect(kind)}", path)

      depth > Protocol.limits().depth ->
        error("native tree exceeds #{Protocol.limits().depth} levels", path)

      true ->
        walk_kind(node, path, depth, state)
    end
  end

  defp walk(other, path, _depth, _state),
    do: error("native node must be a LiveCimgui.UI.Node, got #{inspect(other)}", path)

  defp walk_kind(%Node{kind: :text} = node, path, _depth, state) do
    with :ok <- check_string(node.text, "text content", path, Protocol.max_text_bytes()),
         :ok <- check_no_children(node, path) do
      count_node(state, path)
    end
  end

  defp walk_kind(%Node{kind: :button} = node, path, _depth, state) do
    with :ok <- check_widget(node, path),
         :ok <- check_string(node.label, "button label", path, Protocol.max_text_bytes()),
         :ok <- check_string(node.event, "button event", path, Protocol.max_id_bytes()),
         :ok <- check_no_children(node, path),
         {:ok, state} <- count_node(state, path) do
      register_widget(node, path, state)
    end
  end

  defp walk_kind(%Node{kind: :input} = node, path, _depth, state) do
    with :ok <- check_widget(node, path),
         :ok <- check_string(node.label, "input label", path, Protocol.max_text_bytes()),
         :ok <- check_string(node.value, "input value", path, Protocol.max_text_bytes()),
         :ok <- check_no_children(node, path),
         {:ok, state} <- count_node(state, path) do
      register_widget(node, path, state)
    end
  end

  defp walk_kind(%Node{kind: kind, children: children} = node, path, depth, state)
       when kind in @container_kinds do
    cond do
      not is_list(children) ->
        error("#{kind} children must be a list, got #{inspect(children)}", path)

      Enum.count_until(children, Protocol.limits().children + 1) > Protocol.limits().children ->
        error(
          "#{kind} has #{Enum.count(children)} children, limit is #{Protocol.limits().children}",
          path
        )

      true ->
        walk_children(node, children, path, depth, state, Enum.with_index(children))
    end
  end

  defp walk_kind(%Node{kind: :keyed, key: key, children: children}, path, depth, state) do
    child_path = path <> "/keyed(#{inspect(key)})"

    with :ok <- check_identity(key, "keyed collection key", path),
         :ok <- check_keyed_shape(children, path),
         :ok <- check_unique_keys(children, child_path),
         {:ok, state} <- count_node(state, path) do
      Enum.reduce_while(Enum.with_index(children), {:ok, state}, fn {entry, index}, {:ok, acc} ->
        keyed_step(entry, child_path, index, depth, acc)
      end)
    end
  end

  defp walk_kind(%Node{kind: :diagnostics} = node, path, _depth, state) do
    with :ok <- check_no_children(node, path) do
      count_node(state, path)
    end
  end

  defp keyed_step(entry, child_path, index, depth, state) do
    case walk_keyed_child(entry, child_path, index, depth, state) do
      {:ok, state} -> {:cont, {:ok, state}}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  defp walk_keyed_child({child_key, incarnation, child}, child_path, index, depth, state) do
    with :ok <- check_incarnation(incarnation, "#{child_path}[#{index}]") do
      walk(child, "#{child_path}[#{index}]/key(#{inspect(child_key)})", depth + 1, state)
    end
  end

  defp walk_children(_node, _children, _path, _depth, state, []), do: {:ok, state}

  defp walk_children(node, children, path, depth, state, [{child, index} | rest]) do
    case walk(child, "#{path}/#{index}", depth + 1, state) do
      {:ok, acc} -> walk_children(node, children, path, depth, acc, rest)
      {:error, error} -> {:error, error}
    end
  end

  defp count_node(state, path) do
    count = state.count + 1

    if count > Protocol.limits().nodes do
      error("native tree exceeds #{Protocol.limits().nodes} nodes", path)
    else
      {:ok, %{state | count: count}}
    end
  end

  defp register_widget(%Node{id: id, incarnation: incarnation}, path, state) do
    case Map.fetch(state.ids, id) do
      {:ok, previous_path} ->
        error(
          "duplicate widget id #{inspect(id)} (incarnation #{incarnation}) — already declared at #{previous_path}",
          path
        )

      :error ->
        {:ok, %{state | ids: Map.put(state.ids, id, "#{path} (incarnation #{incarnation})")}}
    end
  end

  defp check_widget(%Node{id: id, incarnation: incarnation}, path) do
    with :ok <- check_identity(id, "widget id", path) do
      check_incarnation(incarnation, path)
    end
  end

  # Identities must be nonempty strings: an empty id would make every empty-id
  # widget share one native identity, and keyed keys must be usable as ID scopes.
  defp check_identity(value, what, path) do
    with :ok <- check_string(value, what, path, Protocol.max_id_bytes()) do
      if value == "" do
        error("#{what} must not be empty", path)
      else
        :ok
      end
    end
  end

  defp check_incarnation(incarnation, path) do
    if is_integer(incarnation) and incarnation >= 1 do
      :ok
    else
      error("widget incarnation must be a positive integer, got #{inspect(incarnation)}", path)
    end
  end

  defp check_string(value, what, path, limit) when is_binary(value) do
    if byte_size(value) > limit do
      error("#{what} is #{byte_size(value)} bytes, limit is #{limit}", path)
    else
      :ok
    end
  end

  defp check_string(value, what, path, _limit),
    do: error("#{what} must be a string, got #{inspect(value)}", path)

  defp check_no_children(%Node{children: []}, _path), do: :ok

  defp check_no_children(%Node{kind: kind}, path),
    do: error("#{kind} cannot have children", path)

  defp check_keyed_shape(children, path) when not is_list(children),
    do: error("keyed children must be a list, got #{inspect(children)}", path)

  defp check_keyed_shape(children, path) do
    limit = Protocol.limits().children

    if Enum.count_until(children, limit + 1) > limit do
      error("keyed collection has #{Enum.count(children)} children, limit is #{limit}", path)
    else
      check_keyed_children_shape(children, path)
    end
  end

  defp check_keyed_children_shape(children, path) do
    Enum.reduce_while(Enum.with_index(children), :ok, fn {child, index}, :ok ->
      case check_keyed_child(child, "#{path}[#{index}]") do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  # A keyed child must be `{key, incarnation, node}` with a usable key: keys are
  # part of the native identity, so an empty, over-long, or non-binary key is an
  # authoring error reported here rather than by the native side.
  defp check_keyed_child({key, incarnation, %Node{} = _node}, path) do
    with :ok <- check_string(key, "keyed child key", path, Protocol.max_id_bytes()) do
      cond do
        key == "" ->
          error("keyed child key must not be empty", path)

        not is_integer(incarnation) or incarnation < 1 ->
          error(
            "keyed child incarnation must be a positive integer, got #{inspect(incarnation)}",
            path
          )

        true ->
          :ok
      end
    end
  end

  defp check_keyed_child({key, _incarnation, other}, path) do
    with :ok <- check_string(key, "keyed child key", path, Protocol.max_id_bytes()) do
      error("keyed child must be a LiveCimgui.UI.Node, got #{inspect(other)}", path)
    end
  end

  defp check_keyed_child(other, path),
    do: error("keyed child must be {key, incarnation, node}, got #{inspect(other)}", path)

  defp check_unique_keys(children, child_path) do
    keys = Enum.map(children, fn {key, _incarnation, _node} -> key end)

    case keys -- Enum.uniq(keys) do
      [] ->
        :ok

      [duplicate | _rest] ->
        error("duplicate keyed child key #{inspect(duplicate)}", child_path)
    end
  end

  defp error(reason, path), do: {:error, Error.exception(reason: reason, path: path)}
end
