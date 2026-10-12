defmodule LiveCimgui.ProtocolRandomTest do
  use ExUnit.Case, async: true

  alias LiveCimgui.Protocol
  alias LiveCimgui.UI
  alias LiveCimgui.UI.Error
  alias LiveCimgui.UI.Node

  # Every test seeds the process-local generator, so the sequences below are the same on every run
  # regardless of test order.
  @seed {1, 2, 3}

  setup do
    :rand.seed(:exsss, @seed)
    :ok
  end

  ## Generators

  defp pick(choices), do: Enum.at(choices, :rand.uniform(length(choices)) - 1)

  defp rand_string(max) do
    case :rand.uniform(max + 1) - 1 do
      0 -> ""
      size -> for(_ <- 1..size, into: "", do: <<?a + :rand.uniform(26) - 1>>)
    end
  end

  defp rand_incarnation, do: :rand.uniform(5)

  defp rand_u64 do
    pick([
      0,
      :rand.uniform(1_000_000),
      18_446_744_073_709_551_615,
      :rand.uniform(18_446_744_073_709_551_616) - 1
    ])
  end

  # Identities must be non-empty on the wire, so generated ids and keys carry a prefix.
  defp rand_widget_id, do: "w" <> rand_string(8)
  defp rand_key, do: "k" <> rand_string(8)

  defp rand_leaf do
    case :rand.uniform(5) do
      1 -> UI.text(rand_string(16))
      2 -> UI.button(rand_widget_id(), rand_string(12), incarnation: rand_incarnation())
      3 -> UI.input(rand_widget_id(), rand_string(16), incarnation: rand_incarnation())
      4 -> UI.diagnostics()
      5 -> UI.text(rand_string(4))
    end
  end

  defp rand_tree(depth) do
    if depth >= 3 do
      rand_leaf()
    else
      case :rand.uniform(7) do
        1 -> rand_leaf()
        2 -> UI.row(rand_children(depth + 1))
        3 -> UI.column(rand_children(depth + 1))
        4 -> UI.keyed(rand_key(), rand_keyed_children(depth + 1))
        5 -> UI.row([])
        6 -> UI.keyed(rand_key(), [])
        7 -> rand_leaf()
      end
    end
  end

  defp child_count, do: :rand.uniform(4) - 1

  defp rand_children(depth) do
    for _ <- 1..child_count()//1, do: rand_tree(depth)
  end

  defp rand_keyed_children(depth) do
    for index <- 1..child_count()//1 do
      key = "k#{index}/#{rand_string(4)}"

      case :rand.uniform(2) do
        1 -> {key, rand_tree(depth)}
        2 -> {key, rand_incarnation(), rand_tree(depth)}
      end
    end
  end

  defp rand_test_input do
    case :rand.uniform(4) do
      1 ->
        {:test_input, :text, rand_string(32)}

      2 ->
        {:test_input, :key, {:rand.uniform(65_536), :rand.uniform(2) == 1}}

      3 ->
        {:test_input, :focus, :rand.uniform(2) == 1}

      4 ->
        {:test_input, :mouse, {pick([:move, :click, :release]), :rand.uniform(), :rand.uniform()}}
    end
  end

  defp rand_message do
    case :rand.uniform(8) do
      1 ->
        {:hello, rand_string(16), rand_u64(), rand_u64(), rand_string(16), :rand.uniform(4_096),
         :rand.uniform(2_160)}

      2 ->
        {:ack, rand_u64(), rand_string(16), rand_incarnation(), rand_u64()}

      3 ->
        {:inspect, rand_u64()}

      4 ->
        {:ping, rand_u64()}

      5 ->
        {:shutdown, pick([:normal, :restart])}

      6 ->
        {:fault, pick([:stall, :crash, :exit])}

      7 ->
        rand_test_input()

      8 ->
        {:snapshot, rand_u64(), rand_u64(), rand_tree(0)}
    end
  end

  # Descriptions built only with the documented constructors: every kind appears, children are
  # nodes, and keyed children are the 2- or 3-tuples `keyed/2` normalizes.
  defp rand_validatable_node(depth) do
    if depth >= 3 do
      rand_leaf()
    else
      case :rand.uniform(4) do
        1 -> rand_leaf()
        2 -> UI.row(rand_validatable_children(depth + 1))
        3 -> UI.column(rand_validatable_children(depth + 1))
        4 -> UI.keyed(rand_key(), rand_validatable_keyed_children(depth + 1))
      end
    end
  end

  defp rand_validatable_children(depth) do
    for _ <- 1..child_count()//1, do: rand_validatable_node(depth)
  end

  defp rand_validatable_keyed_children(depth) do
    for index <- 1..child_count()//1 do
      key = "k#{index}"

      if :rand.uniform(2) == 1 do
        {key, rand_validatable_node(depth)}
      else
        {key, pick([rand_incarnation(), 0]), rand_validatable_node(depth)}
      end
    end
  end

  defp rand_unvalidated_child do
    case :rand.uniform(6) do
      1 -> UI.text(rand_string(4))
      2 -> rand_string(4)
      3 -> :not_a_node
      4 -> {rand_string(4), UI.text("x")}
      5 -> {rand_string(4), rand_incarnation(), UI.text("x")}
      6 -> {rand_string(4), 0, UI.text("x")}
    end
  end

  defp rand_any_node(depth) do
    case :rand.uniform(7) do
      1 ->
        rand_leaf()

      2 ->
        UI.row(rand_any_children(depth + 1))

      3 ->
        UI.column(rand_any_children(depth + 1))

      4 ->
        %Node{kind: :keyed, key: rand_string(8), children: rand_any_children(depth + 1)}

      5 ->
        %Node{kind: pick([:slider, :window, :text]), text: rand_string(4), children: []}

      6 ->
        %Node{kind: :keyed, key: "rows", children: rand_any_children(depth + 1)}

      7 ->
        pick([UI.text("x"), %Node{kind: :row, children: rand_any_children(depth + 1)}])
    end
  end

  defp rand_any_children(depth) do
    for _ <- 1..child_count()//1, do: rand_unvalidated_child() |> maybe_nested(depth)
  end

  defp maybe_nested(child, depth) do
    if depth < 2 and :rand.uniform(3) == 1 do
      rand_any_node(depth + 1)
    else
      child
    end
  end

  defp shuffle([]), do: []

  defp shuffle(list) do
    {item, rest} = List.pop_at(list, :rand.uniform(length(list)) - 1)
    [item | shuffle(rest)]
  end

  ## Round trips

  test "decode(encode(message)) returns the original for hundreds of random messages" do
    messages = for _ <- 1..300, do: rand_message()

    for message <- messages do
      assert {:ok, frame} = Protocol.encode(message)
      assert {:ok, ^message} = Protocol.decode(frame)
    end

    assert MapSet.new(messages, &elem(&1, 0)) ==
             MapSet.new([
               :hello,
               :snapshot,
               :ack,
               :inspect,
               :ping,
               :shutdown,
               :fault,
               :test_input
             ])
  end

  test "snapshot frames carry random descriptions intact" do
    trees = for _ <- 1..200, do: rand_tree(0)

    for tree <- trees do
      view_generation = rand_u64()
      ui_revision = rand_u64()
      frame = Protocol.encode!({:snapshot, view_generation, ui_revision, tree})

      assert {:ok, {:snapshot, ^view_generation, ^ui_revision, %Node{} = decoded}} =
               Protocol.decode(frame)

      assert decoded == tree
      assert UI.widgets(decoded) == UI.widgets(tree)
    end
  end

  test "a keyed collection's widget set is independent of order and entry incarnation" do
    for _ <- 1..40 do
      record_count = :rand.uniform(6)

      records =
        for index <- 1..record_count do
          %{
            key: "key/#{index}",
            id: "widget/#{index}",
            incarnation: rand_incarnation(),
            entry_incarnation: rand_incarnation(),
            value: rand_string(8)
          }
        end

      build = fn order ->
        UI.keyed(
          "rows",
          Enum.map(order, fn record ->
            widget = UI.input(record.id, record.value, incarnation: record.incarnation)
            {record.key, record.entry_incarnation, widget}
          end)
        )
      end

      trees = [build.(records), build.(Enum.reverse(records)), build.(shuffle(records))]
      expected = MapSet.new(records, &{&1.id, &1.incarnation})

      decoded =
        for tree <- trees do
          assert MapSet.new(UI.widgets(tree)) == expected

          {:ok, {:snapshot, 0, 0, %Node{} = node}} =
            Protocol.decode(Protocol.encode!({:snapshot, 0, 0, tree}))

          node
        end

      for node <- decoded do
        assert MapSet.new(UI.widgets(node)) == expected
      end

      node_for = fn node, key ->
        Enum.find_value(node.children, fn {child_key, _incarnation, child} ->
          if child_key == key, do: child
        end)
      end

      for record <- records do
        identity = node_for.(hd(decoded), record.key)

        assert identity == UI.input(record.id, record.value, incarnation: record.incarnation)

        for node <- decoded do
          assert node_for.(node, record.key) == identity
        end
      end
    end
  end

  ## Malformed input

  test "decode/1 never raises on malformed frames and returns {:error, _} or {:more, _}" do
    valid_frames = [
      Protocol.encode!({:ping, 7}),
      Protocol.encode!({:hello, "session", 1, 2, "title", 800, 600}),
      Protocol.encode!({:snapshot, 0, 1, UI.column([UI.text("a"), UI.input("name", "v")])})
    ]

    truncations =
      for frame <- valid_frames, length <- 0..(byte_size(frame) - 1) do
        binary_part(frame, 0, length)
      end

    # A version byte that cannot be the supported one is rejected before any body is decoded.
    bad_versions =
      for _ <- 1..120 do
        size = :rand.uniform(24) - 1

        <<size::little-32, pick([0, 2, 3, 255, 2 + :rand.uniform(253)])::8,
          pick([1, 2, 7, 16, 33, 40])::8, :rand.bytes(size)::binary>>
      end

    unknown_types =
      for _ <- 1..80 do
        size = :rand.uniform(24) - 1

        <<size::little-32, Protocol.version()::8, pick([8, 9, 15, 18, 31, 41, 63, 99, 255])::8,
          :rand.bytes(size)::binary>>
      end

    random_bytes = for _ <- 1..120, do: :rand.bytes(:rand.uniform(40) - 1)

    for frame <- truncations ++ bad_versions ++ unknown_types ++ random_bytes do
      result = Protocol.decode(frame)

      assert match?({:error, _}, result) or match?({:more, _}, result),
             "expected an error or {:more, n} for #{inspect(frame)}, got: #{inspect(result)}"
    end
  end

  test "decode/1 never raises on random complete snapshot bodies" do
    outcomes =
      for _ <- 1..300 do
        body = :rand.bytes(:rand.uniform(24) - 1)

        frame =
          <<byte_size(body)::little-32, Protocol.version()::8, Protocol.type_code(:snapshot)::8,
            body::binary>>

        try do
          case Protocol.decode(frame) do
            {:ok, {:snapshot, _view_generation, _ui_revision, %Node{}}} -> :snapshot
            {:error, _reason} -> :error
            {:more, _needed} -> :more
          end
        rescue
          exception -> {:raised, exception.__struct__}
        end
      end

    assert Enum.all?(outcomes, fn
             outcome when outcome in [:snapshot, :error, :more] -> true
             _other -> false
           end)
  end

  ## Description validation

  test "validate/1 never raises on random descriptions from the supported vocabulary" do
    for _ <- 1..300 do
      node = rand_validatable_node(0)

      case UI.validate(node) do
        {:ok, %Node{} = accepted} -> assert accepted == node
        {:error, %Error{}} -> :ok
      end
    end
  end

  test "validate/1 never raises on arbitrary node structures" do
    outcomes =
      for _ <- 1..300 do
        node = rand_any_node(0)

        try do
          classify_validation(UI.validate(node))
        rescue
          # A raise is a defect: `validate/1` must be total, so any exception
          # (including a FunctionClauseError from an unrecognised result) is
          # reported as a failure by the assertion below.
          exception -> {:raised, exception.__struct__}
        end
      end

    assert Enum.all?(outcomes, fn outcome -> outcome in [:ok, :error] end)
  end

  defp classify_validation({:ok, _node}), do: :ok
  defp classify_validation({:error, %Error{}}), do: :error
end
