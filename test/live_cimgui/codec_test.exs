defmodule LiveCimgui.CodecTest do
  use ExUnit.Case, async: true

  alias LiveCimgui.Protocol
  alias LiveCimgui.UI
  alias LiveCimgui.UI.Node

  # Node tag bytes; see `LiveCimgui.Protocol.Codec.node_tags/0`.
  @text 1
  @button 2
  @input 3
  @row 4
  @column 5
  @keyed 6
  @diagnostics 7

  defp frame(type, body) do
    <<byte_size(body)::little-32, Protocol.version()::8, type::8, body::binary>>
  end

  defp type_code(name), do: Protocol.type_code(name)

  defp u8(value), do: <<value::8>>
  defp u32(value), do: <<value::little-32>>
  defp u64(value), do: <<value::little-64>>
  defp f64(value), do: <<value::little-float-64>>
  defp string(value), do: <<byte_size(value)::little-32, value::binary>>
  defp iodata(parts), do: IO.iodata_to_binary(parts)

  defp repeat_text(count), do: iodata(List.duplicate(iodata([u8(@text), string("a")]), count))

  defp snapshot_body(tree_bytes, view_generation \\ 0, ui_revision \\ 0) do
    iodata([u64(view_generation), u64(ui_revision), tree_bytes])
  end

  # Snapshot frames carry a complete message: {:snapshot, view_generation, ui_revision, tree}.
  defp snapshot_round_trip!(tree, view_generation \\ 0, ui_revision \\ 0) do
    assert {:ok, {:snapshot, ^view_generation, ^ui_revision, ^tree}} =
             Protocol.decode(Protocol.encode!({:snapshot, view_generation, ui_revision, tree}))
  end

  defp decode_snapshot_tree!(frame) do
    case Protocol.decode(frame) do
      {:ok, {:snapshot, _view_generation, _ui_revision, %Node{} = tree}} -> tree
      other -> flunk("expected a decoded snapshot message, got: #{inspect(other)}")
    end
  end

  defp decode_crafted_tree!(tree_bytes) do
    decode_snapshot_tree!(frame(type_code(:snapshot), snapshot_body(tree_bytes)))
  end

  describe "snapshot trees" do
    test "snapshot frames round trip every node kind" do
      cases = [
        UI.text("plain"),
        UI.button("go", "Go"),
        UI.button("go", "Go", event: "go:click", incarnation: 4),
        UI.input("name", "value"),
        UI.input("name", "value", label: "Name", incarnation: 2),
        UI.row([UI.text("a"), UI.text("b")]),
        UI.column([UI.text("a"), UI.row([UI.text("b")])]),
        UI.diagnostics(),
        %Node{kind: :diagnostics},
        UI.keyed("rows", [{"a", UI.text("A")}, {"b", UI.text("B")}]),
        UI.keyed("rows", [{"a", 5, UI.input("row/a", "A")}, {"b", 7, UI.button("row/b", "B")}]),
        UI.column([
          UI.text("title"),
          UI.button("go", "Go"),
          UI.input("name", "value", label: "Name"),
          UI.row([UI.text("a"), UI.text("b")]),
          UI.keyed("rows", [{"a", 2, UI.input("row/a", "A")}, {"b", UI.input("row/b", "B")}]),
          UI.diagnostics()
        ])
      ]

      for tree <- cases do
        snapshot_round_trip!(tree)
      end
    end

    test "the envelope carries the view generation and the UI revision" do
      tree = UI.keyed("rows", [{"a", 5, UI.text("A")}, {"b", 7, UI.input("row/b", "B")}])

      assert {:ok, {:snapshot, 4, 9, decoded}} =
               Protocol.decode(Protocol.encode!({:snapshot, 4, 9, tree}))

      assert decoded == tree
      assert UI.keyed("rows", [{"a", UI.text("A")}]).children == [{"a", 1, UI.text("A")}]
    end

    test "node tag bytes and field order match the documented wire table" do
      cases = [
        {iodata([u8(@text), string("x")]), %Node{kind: :text, text: "x"}},
        {iodata([u8(@diagnostics)]), %Node{kind: :diagnostics}},
        {iodata([u8(@row), u32(0)]), %Node{kind: :row, children: []}},
        {iodata([u8(@column), u32(0)]), %Node{kind: :column, children: []}},
        {iodata([u8(@keyed), string("rows"), u32(0)]),
         %Node{kind: :keyed, key: "rows", children: []}},
        {iodata([u8(@button), string("go"), u64(3), string("Go"), string("go:click")]),
         %Node{kind: :button, id: "go", incarnation: 3, label: "Go", event: "go:click"}},
        {iodata([u8(@input), string("name"), u64(2), string("Name"), string("value")]),
         %Node{kind: :input, id: "name", incarnation: 2, label: "Name", value: "value"}}
      ]

      for {tree_bytes, expected} <- cases do
        assert decode_crafted_tree!(tree_bytes) == expected
      end
    end

    test "keyed reorder round trip keeps identity by key, not by position" do
      first =
        UI.keyed("rows", [{"a", UI.input("editor/a", "1")}, {"b", UI.input("editor/b", "2")}])

      second =
        UI.keyed("rows", [{"b", UI.input("editor/b", "2")}, {"a", UI.input("editor/a", "1")}])

      assert first.children == [
               {"a", 1, UI.input("editor/a", "1")},
               {"b", 1, UI.input("editor/b", "2")}
             ]

      snapshot_round_trip!(first)
      snapshot_round_trip!(second)

      keys_in_wire_order = fn tree ->
        decoded = decode_snapshot_tree!(Protocol.encode!({:snapshot, 0, 0, tree}))
        Enum.map(decoded.children, fn {key, _incarnation, _node} -> key end)
      end

      # Wire order follows the description order; identity follows the key.
      assert keys_in_wire_order.(first) == ["a", "b"]
      assert keys_in_wire_order.(second) == ["b", "a"]

      by_key = fn tree ->
        decoded = decode_snapshot_tree!(Protocol.encode!({:snapshot, 0, 0, tree}))
        Map.new(decoded.children, fn {key, incarnation, node} -> {key, {incarnation, node}} end)
      end

      assert by_key.(first) == by_key.(second)
      assert by_key.(first)["a"] == {1, UI.input("editor/a", "1")}
      assert by_key.(first)["b"] == {1, UI.input("editor/b", "2")}
    end

    test "the codec preserves duplicate widget ids and duplicate keyed keys" do
      # Uniqueness is a `LiveCimgui.UI.validate/1` rule; the codec only carries the tree.
      snapshot_round_trip!(UI.column([UI.input("a", "1"), UI.input("a", "2")]))
      snapshot_round_trip!(UI.keyed("rows", [{"a", UI.text("1")}, {"a", UI.text("2")}]))
    end

    test "rejects a text or identity string longer than its limit" do
      text_too_long = snapshot_body(iodata([u8(@text), u32(65_537)]))

      assert {:error, {:string_too_long, %{size: 65_537, limit: 65_536}}} =
               Protocol.decode(frame(type_code(:snapshot), text_too_long))

      button_id_too_long = snapshot_body(iodata([u8(@button), u32(257)]))

      assert {:error, {:string_too_long, %{size: 257, limit: 256}}} =
               Protocol.decode(frame(type_code(:snapshot), button_id_too_long))

      keyed_key_too_long =
        snapshot_body(iodata([u8(@keyed), string("rows"), u32(1), u32(257)]))

      assert {:error, {:string_too_long, %{size: 257, limit: 256}}} =
               Protocol.decode(frame(type_code(:snapshot), keyed_key_too_long))
    end

    test "rejects an empty widget id or keyed key" do
      empty_button = iodata([u8(@button), string(""), u64(1), string("Go"), string("go")])

      assert {:error, {:invalid_identity, %{field: :widget_id, value: ""}}} =
               Protocol.decode(frame(type_code(:snapshot), snapshot_body(empty_button)))

      empty_input =
        iodata([u8(@input), string(""), u64(1), string("Name"), string("value")])

      assert {:error, {:invalid_identity, %{field: :widget_id, value: ""}}} =
               Protocol.decode(frame(type_code(:snapshot), snapshot_body(empty_input)))

      empty_collection_key = iodata([u8(@keyed), string(""), u32(0)])

      assert {:error, {:invalid_identity, %{field: :key, value: ""}}} =
               Protocol.decode(frame(type_code(:snapshot), snapshot_body(empty_collection_key)))

      empty_child_key =
        iodata([u8(@keyed), string("rows"), u32(1), string(""), u64(1), u8(@text), string("x")])

      assert {:error, {:invalid_identity, %{field: :key, value: ""}}} =
               Protocol.decode(frame(type_code(:snapshot), snapshot_body(empty_child_key)))
    end

    test "rejects a tree deeper than limits().depth" do
      # 63 nested columns plus the leaf are exactly 64 levels deep.
      boundary = Enum.reduce(1..63, UI.text("x"), fn _, inner -> UI.column([inner]) end)
      snapshot_round_trip!(boundary)

      too_deep = UI.column([boundary])

      assert {:error, {:tree_too_deep, %{depth: 65, limit: 64}}} =
               Protocol.encode({:snapshot, 0, 0, too_deep})

      tree_bytes =
        Enum.reduce(1..64, iodata([u8(@text), string("x")]), fn _, inner ->
          iodata([u8(@column), u32(1), inner])
        end)

      assert {:error, {:tree_too_deep, %{depth: 65, limit: 64}}} =
               Protocol.decode(frame(type_code(:snapshot), snapshot_body(tree_bytes)))
    end

    test "rejects a container with more children than limits().children" do
      too_many = List.duplicate(UI.text("x"), 1_025)

      assert {:error, {:too_many_children, 1_025}} =
               Protocol.encode({:snapshot, 0, 0, UI.row(too_many)})

      assert {:error, {:too_many_children, 1_025}} =
               Protocol.encode(
                 {:snapshot, 0, 0, UI.keyed("rows", List.duplicate({"a", UI.text("x")}, 1_025))}
               )

      snapshot_round_trip!(UI.row(List.duplicate(UI.text("x"), 1_024)))

      # The decoder enforces the same limit before it parses any child.
      column_1_030 = snapshot_body(iodata([u8(@column), u32(1_030)]))

      assert {:error, {:too_many_children, 1_030}} =
               Protocol.decode(frame(type_code(:snapshot), column_1_030))

      keyed_1_030 = snapshot_body(iodata([u8(@keyed), string("rows"), u32(1_030)]))

      assert {:error, {:too_many_children, 1_030}} =
               Protocol.decode(frame(type_code(:snapshot), keyed_1_030))

      # 1_024 children are accepted.
      assert %Node{kind: :column, children: children} =
               decode_crafted_tree!(iodata([u8(@column), u32(1_024), repeat_text(1_024)]))

      assert Enum.count_until(children, 1_025) == 1_024
    end

    test "rejects a tree with more nodes than limits().nodes" do
      wide = UI.column(Enum.map(1..1_024, fn _ -> UI.column(List.duplicate(UI.text("a"), 4)) end))

      assert {:error, {:too_many_nodes, 4_097}} = Protocol.encode({:snapshot, 0, 0, wide})

      tree_bytes =
        iodata([
          u8(@column),
          u32(1_024),
          Enum.map(1..1_024, fn _ ->
            iodata([
              u8(@column),
              u32(4),
              Enum.map(1..4, fn _ -> iodata([u8(@text), string("a")]) end)
            ])
          end)
        ])

      assert {:error, {:too_many_nodes, 4_097}} =
               Protocol.decode(frame(type_code(:snapshot), snapshot_body(tree_bytes)))
    end
  end

  describe "body rejections" do
    test "rejects truncated bodies" do
      assert {:error, {:truncated, :u64}} = Protocol.decode(frame(type_code(:ping), u32(1)))

      # ack/5 starts with view_generation (u64), then the id string.
      assert {:error, {:truncated, :u64}} = Protocol.decode(frame(type_code(:ack), <<>>))

      assert {:error, {:truncated, :string_length}} =
               Protocol.decode(frame(type_code(:ack), u64(3)))

      assert {:error, {:truncated, {:string, 5}}} =
               Protocol.decode(frame(type_code(:ack), iodata([u64(3), u32(5), "ab"])))

      assert {:error, {:truncated, :string_length}} =
               Protocol.decode(frame(type_code(:snapshot), snapshot_body(iodata([u8(@text)]))))

      # A body that ends before any node, or before a declared child, is truncated.
      assert {:error, {:truncated, :node}} =
               Protocol.decode(frame(type_code(:snapshot), snapshot_body(<<>>)))

      assert {:error, {:truncated, :node}} =
               Protocol.decode(
                 frame(type_code(:snapshot), snapshot_body(iodata([u8(@row), u32(1)])))
               )

      assert {:error, {:truncated, :node}} =
               Protocol.decode(
                 frame(
                   type_code(:snapshot),
                   snapshot_body(
                     iodata([u8(@keyed), string("rows"), u32(1), string("a"), u64(1)])
                   )
                 )
               )

      assert {:error, {:truncated, :shutdown}} =
               Protocol.decode(frame(type_code(:shutdown), <<>>))

      assert {:error, {:truncated, :fault}} = Protocol.decode(frame(type_code(:fault), <<>>))

      assert {:error, {:truncated, :test_input}} =
               Protocol.decode(frame(type_code(:test_input), <<>>))
    end

    test "rejects a body with trailing bytes" do
      bodies = [
        {type_code(:hello),
         iodata([string("session"), u64(1), u64(2), string("title"), u32(800), u32(600)])},
        {type_code(:snapshot), snapshot_body(iodata([u8(@text), string("x")]))},
        {type_code(:ack), iodata([u64(3), string("widget"), u64(2), u64(4)])},
        {type_code(:set_value),
         iodata([u64(5), string("widget"), u64(2), u64(4), string("text")])},
        {type_code(:inspect), u64(7)},
        {type_code(:ping), u64(8)},
        {type_code(:test_input), iodata([u8(0), string("typed")])},
        {type_code(:ready),
         iodata([
           string("session"),
           u64(1),
           u64(2),
           string("2.30"),
           string("GL"),
           string("1.0"),
           u64(1234)
         ])},
        {type_code(:event), iodata([u64(1), u64(2), u8(2)])},
        {type_code(:diagnostics),
         iodata([
           u64(1),
           u64(2),
           u64(3),
           string("focus"),
           u32(0),
           u32(0),
           u64(0),
           u64(0),
           u64(0),
           u32(0),
           u32(0),
           f64(1.0)
         ])},
        {type_code(:overload), iodata([u8(0), u64(5), u8(7), string("detail")])},
        {type_code(:inspect_result),
         iodata([u64(9), u64(11), u64(22), u64(33), string("focus"), u32(0), u32(0), u64(999)])},
        {type_code(:drafts), iodata([u64(1), u32(0)])},
        {type_code(:pong), u64(3)},
        {type_code(:bye), iodata([u8(4), string("bye")])},
        {type_code(:protocol_error), iodata([u8(5), string("oops")])}
      ]

      for {type, body} <- bodies do
        assert {:ok, _message} = Protocol.decode(frame(type, body))

        assert {:error, {:trailing_bytes, 1}} =
                 Protocol.decode(frame(type, iodata([body, <<0>>])))
      end
    end

    test "rejects an unknown node tag" do
      assert {:error, {:invalid_node_tag, 99}} =
               Protocol.decode(
                 frame(type_code(:snapshot), snapshot_body(iodata([u8(99), string("x")])))
               )

      nested = iodata([u8(@row), u32(1), u8(200)])

      assert {:error, {:invalid_node_tag, 200}} =
               Protocol.decode(frame(type_code(:snapshot), snapshot_body(nested)))
    end

    test "rejects an unknown event kind" do
      event = fn payload -> frame(type_code(:event), iodata([u64(1), u64(2), payload])) end

      assert {:error, {:invalid_event_kind, 99}} = Protocol.decode(event.(u8(99)))
      assert {:error, {:truncated, :event}} = Protocol.decode(event.(<<>>))

      assert {:error, {:truncated, {:string, 8}}} =
               Protocol.decode(event.(iodata([u8(0), u32(8), "ab"])))
    end

    test "rejects an unknown shutdown reason code and an unknown fault code" do
      assert {:error, {:unknown_reason_code, 9}} =
               Protocol.decode(frame(type_code(:shutdown), u8(9)))

      assert {:error, {:truncated, :shutdown}} =
               Protocol.decode(frame(type_code(:shutdown), iodata([u8(9), u8(9)])))

      assert {:error, {:unknown_fault_code, 7}} = Protocol.decode(frame(type_code(:fault), u8(7)))
    end

    test "rejects an unknown test-input kind" do
      test_input = fn body -> frame(type_code(:test_input), body) end

      assert {:error, {:invalid_test_input, 9}} = Protocol.decode(test_input.(u8(9)))
      assert {:error, {:truncated, :test_input}} = Protocol.decode(test_input.(<<>>))

      assert {:error, {:invalid_test_input, {:mouse, 9}}} =
               Protocol.decode(test_input.(iodata([u8(3), u8(9), f64(0), f64(0)])))

      assert {:error, {:truncated, :test_mouse}} =
               Protocol.decode(test_input.(iodata([u8(3), u8(0)])))
    end

    test "rejects an unknown overload code" do
      assert {:error, {:unknown_overload_code, 10}} =
               Protocol.decode(
                 frame(type_code(:overload), iodata([u8(10), u64(5), u8(7), string("detail")]))
               )
    end
  end

  describe "host-to-Elixir messages" do
    test "decodes hello with the session, generations, title, and window size" do
      body = iodata([string("session"), u64(3), u64(4), string("title"), u32(1024), u32(768)])

      assert {:ok, {:hello, "session", 3, 4, "title", 1024, 768}} =
               Protocol.decode(frame(type_code(:hello), body))
    end

    test "decodes ready, pong, bye, and protocol_error" do
      ready =
        iodata([
          string("session"),
          u64(1),
          u64(2),
          string("2.30.0"),
          string("OpenGL"),
          string("1.0"),
          u64(1234)
        ])

      assert {:ok,
              {:ready,
               %{
                 session_id: "session",
                 host_generation: 1,
                 view_generation: 2,
                 sdl_version: "2.30.0",
                 gl_renderer: "OpenGL",
                 gl_version: "1.0",
                 pid: 1234
               }}} = Protocol.decode(frame(type_code(:ready), ready))

      assert {:ok, {:pong, 7}} = Protocol.decode(frame(type_code(:pong), u64(7)))

      assert {:ok, {:bye, %{code: 4, detail: "bye"}}} =
               Protocol.decode(frame(type_code(:bye), iodata([u8(4), string("bye")])))

      assert {:ok, {:protocol_error, %{code: 5, detail: "oops"}}} =
               Protocol.decode(frame(type_code(:protocol_error), iodata([u8(5), string("oops")])))
    end

    test "decodes drafts with their full text" do
      body =
        iodata([
          u64(1),
          u32(2),
          string("first"),
          u64(2),
          u64(3),
          u64(4),
          string("one"),
          string("second"),
          u64(5),
          u64(6),
          u64(7),
          string("two")
        ])

      assert {:ok,
              {:drafts, 1,
               [
                 %{
                   id: "first",
                   incarnation: 2,
                   draft_revision: 3,
                   ack_revision: 4,
                   text: "one"
                 },
                 %{
                   id: "second",
                   incarnation: 5,
                   draft_revision: 6,
                   ack_revision: 7,
                   text: "two"
                 }
               ]}} = Protocol.decode(frame(type_code(:drafts), body))

      assert {:ok, {:drafts, 9, []}} =
               Protocol.decode(frame(type_code(:drafts), iodata([u64(9), u32(0)])))
    end

    test "decodes diagnostics, including focus_id and drafts" do
      body =
        iodata([
          u64(11),
          u64(22),
          u64(33),
          string("focus/widget"),
          u32(1),
          string("draft"),
          u64(2),
          u64(3),
          u64(4),
          u32(5),
          u64(55),
          u64(66),
          u64(77),
          u32(1_024),
          u32(768),
          f64(2.0)
        ])

      assert {:ok,
              {:diagnostics,
               %{
                 frame_count: 11,
                 applied_ui_revision: 22,
                 view_generation: 33,
                 focus_id: "focus/widget",
                 drafts: [
                   %{id: "draft", incarnation: 2, draft_revision: 3, ack_revision: 4}
                 ],
                 window_width: 1_024,
                 window_height: 768,
                 framebuffer_scale: 2.0,
                 outbound_queue: 5,
                 overloads: 55,
                 dropped_commands: 66,
                 uptime_ms: 77
               }}} = Protocol.decode(frame(type_code(:diagnostics), body))
    end

    test "decodes every overload reason code" do
      codes = [
        {0, :outbound_full},
        {1, :command_full},
        {2, :draft_full},
        {3, :frame_oversized},
        {4, :unknown_message},
        {5, :stale_session},
        {6, :stale_generation},
        {7, :stale_incarnation},
        {8, :stale_revision},
        {9, :malformed_frame}
      ]

      for {code, name} <- codes do
        body = iodata([u8(code), u64(5), u8(7), string("detail")])

        assert {:ok, {:overload, %{code: ^name, dropped: 5, queue: 7, detail: "detail"}}} =
                 Protocol.decode(frame(type_code(:overload), body))
      end
    end

    test "decodes inspect_result widgets, rects, and uptime" do
      widget =
        iodata([
          string("w1"),
          u64(2),
          u64(3),
          u64(4),
          u8(1),
          u32(5),
          u32(6),
          u32(7),
          string("body")
        ])

      rect = iodata([string("w1"), f64(1.5), f64(2.5), f64(3.5), f64(4.5)])

      body =
        iodata([
          u64(9),
          u64(11),
          u64(22),
          u64(33),
          string("focus/widget"),
          u32(1),
          widget,
          u32(1),
          rect,
          u64(999)
        ])

      assert {:ok,
              {:inspect_result,
               %{
                 request_id: 9,
                 frame_count: 11,
                 applied_ui_revision: 22,
                 view_generation: 33,
                 focus_id: "focus/widget",
                 widgets: [
                   %{
                     id: "w1",
                     incarnation: 2,
                     draft_revision: 3,
                     ack_revision: 4,
                     # The wire byte is decoded into the boolean `:active`, not `:active?`.
                     active: true,
                     cursor: 5,
                     selection: {6, 7},
                     text: "body"
                   }
                 ],
                 rects: [%{id: "w1", min: {1.5, 2.5}, max: {3.5, 4.5}}],
                 uptime_ms: 999
               }}} = Protocol.decode(frame(type_code(:inspect_result), body))

      inactive =
        iodata([string("w2"), u64(8), u64(9), u64(10), u8(0), u32(0), u32(0), u32(0), string("")])

      empty =
        iodata([u64(9), u64(11), u64(22), u64(33), string(""), u32(1), inactive, u32(0), u64(7)])

      assert {:ok,
              {:inspect_result, %{widgets: [%{active: false, text: ""}], rects: [], uptime_ms: 7}}} =
               Protocol.decode(frame(type_code(:inspect_result), empty))
    end

    test "decodes every event payload shape" do
      event = fn payload -> frame(type_code(:event), iodata([u64(1), u64(2), payload])) end

      assert {:ok, {:event, 1, 2, {:button_click, "button", 3, "go"}}} =
               Protocol.decode(event.(iodata([u8(0), string("button"), u64(3), string("go")])))

      assert {:ok, {:event, 1, 2, {:input_edit, "widget", 3, 4, "hello"}}} =
               Protocol.decode(
                 event.(iodata([u8(1), string("widget"), u64(3), u64(4), string("hello")]))
               )

      assert {:ok, {:event, 1, 2, {:input_submit, "widget", 3, 4, "hello"}}} =
               Protocol.decode(
                 event.(iodata([u8(3), string("widget"), u64(3), u64(4), string("hello")]))
               )

      assert {:ok, {:event, 1, 2, :window_close}} = Protocol.decode(event.(u8(2)))
    end

    test "decodes every test-input payload shape" do
      test_input = fn body -> frame(type_code(:test_input), body) end

      assert {:ok, {:test_input, :text, "typed"}} =
               Protocol.decode(test_input.(iodata([u8(0), string("typed")])))

      assert {:ok, {:test_input, :key, {65, true}}} =
               Protocol.decode(test_input.(iodata([u8(1), u32(65), u8(1)])))

      assert {:ok, {:test_input, :key, {65, false}}} =
               Protocol.decode(test_input.(iodata([u8(1), u32(65), u8(0)])))

      assert {:ok, {:test_input, :focus, false}} =
               Protocol.decode(test_input.(iodata([u8(2), u8(0)])))

      assert {:ok, {:test_input, :mouse, {:move, 1.5, 2.5}}} =
               Protocol.decode(test_input.(iodata([u8(3), u8(0), f64(1.5), f64(2.5)])))

      assert {:ok, {:test_input, :mouse, {:click, 3.0, 4.0}}} =
               Protocol.decode(test_input.(iodata([u8(3), u8(1), f64(3.0), f64(4.0)])))

      assert {:ok, {:test_input, :mouse, {:release, 5.0, 6.0}}} =
               Protocol.decode(test_input.(iodata([u8(3), u8(2), f64(5.0), f64(6.0)])))
    end
  end
end
