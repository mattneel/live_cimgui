defmodule LiveCimgui.UITest do
  use ExUnit.Case, async: true

  alias LiveCimgui.Protocol
  alias LiveCimgui.UI
  alias LiveCimgui.UI.Error
  alias LiveCimgui.UI.Node

  # The description from the `LiveCimgui.UI` moduledoc.
  defp demo do
    UI.column([
      UI.text("live_cimgui - Native interaction. Elixir application state."),
      UI.input("draft", "draft text"),
      UI.row([
        UI.button("busy", "Busy Elixir for 5 seconds"),
        UI.button("reverse", "Reverse keyed list"),
        UI.button("add", "Add row"),
        UI.button("remove", "Remove row"),
        UI.button("restart-view", "Restart view")
      ]),
      UI.keyed("rows", [
        {"alpha", 1, UI.input("editor/alpha", "one")},
        {"beta", 1, UI.input("editor/beta", "two")}
      ]),
      UI.diagnostics()
    ])
  end

  defp error_message(fun) do
    assert {:error, %Error{} = error} = fun.()
    error.message
  end

  describe "constructors" do
    test "constructors produce the documented structs" do
      assert UI.text("hello") == %Node{kind: :text, text: "hello"}

      assert UI.button("go", "Go") ==
               %Node{kind: :button, id: "go", label: "Go", event: "go", incarnation: 1}

      assert UI.button("go", "Go", event: "go:click") ==
               %Node{kind: :button, id: "go", label: "Go", event: "go:click", incarnation: 1}

      assert UI.button("go", "Go", incarnation: 4) ==
               %Node{kind: :button, id: "go", label: "Go", event: "go", incarnation: 4}

      assert UI.input("name", "value") ==
               %Node{kind: :input, id: "name", value: "value", label: "", incarnation: 1}

      assert UI.input("name", "value", label: "Name", incarnation: 2) ==
               %Node{kind: :input, id: "name", value: "value", label: "Name", incarnation: 2}

      assert UI.row([UI.text("a")]) == %Node{kind: :row, children: [UI.text("a")]}
      assert UI.column([UI.text("a")]) == %Node{kind: :column, children: [UI.text("a")]}
      assert UI.diagnostics() == %Node{kind: :diagnostics}
      assert UI.keyed("rows", []) == %Node{kind: :keyed, key: "rows", children: []}

      assert UI.keyed("rows", [{"a", UI.text("A")}]) ==
               %Node{kind: :keyed, key: "rows", children: [{"a", 1, UI.text("A")}]}

      assert UI.keyed("rows", [{"a", 3, UI.text("A")}]) ==
               %Node{kind: :keyed, key: "rows", children: [{"a", 3, UI.text("A")}]}
    end

    test "constructors raise LiveCimgui.UI.Error for malformed input" do
      assert_raise Error, ~r/text content must be a string/, fn -> UI.text(1) end
      assert_raise Error, ~r/row children must be a list/, fn -> UI.row("not a list") end
      assert_raise Error, ~r/column children must be a list/, fn -> UI.column(1) end

      assert_raise Error, ~r/keyed child must be/, fn -> UI.keyed("rows", ["not a child"]) end

      assert_raise Error, ~r/keyed child must be/, fn ->
        UI.keyed("rows", [{:not_a_string, UI.text("A")}])
      end
    end
  end

  describe "validate/1 acceptances" do
    test "accepts every documented kind and returns the node unchanged" do
      cases = [
        UI.text("plain"),
        UI.button("go", "Go"),
        UI.button("go", "Go", event: "go:click", incarnation: 4),
        UI.input("name", "value"),
        UI.input("name", "value", label: "Name", incarnation: 2),
        UI.diagnostics(),
        UI.row([]),
        UI.column([]),
        UI.row([UI.text("a"), UI.button("go", "Go")]),
        UI.column([UI.text("a"), UI.row([UI.text("b")])]),
        UI.keyed("rows", []),
        UI.keyed("rows", [{"a", UI.text("A")}, {"b", 2, UI.input("row/b", "B")}]),
        UI.keyed("outer", [{"o1", 3, UI.keyed("inner", [{"i1", 1, UI.text("deep")}])}])
      ]

      for node <- cases do
        assert {:ok, ^node} = UI.validate(node)
        assert UI.validate!(node) == node
      end
    end

    test "accepts a full demo-shaped description and returns the node unchanged" do
      tree = demo()

      assert {:ok, ^tree} = UI.validate(tree)
      assert UI.validate!(tree) == tree

      assert UI.widgets(tree) == [
               {"draft", 1},
               {"busy", 1},
               {"reverse", 1},
               {"add", 1},
               {"remove", 1},
               {"restart-view", 1},
               {"editor/alpha", 1},
               {"editor/beta", 1}
             ]

      assert {:ok, _frame} = Protocol.encode({:snapshot, 0, 1, tree})
    end
  end

  describe "validate/1 rejections" do
    test "rejects an unsupported native kind" do
      message = error_message(fn -> UI.validate(%Node{kind: :slider}) end)
      assert message =~ "unsupported native kind :slider"
      assert message =~ "at <root>"
    end

    test "rejects something that is not a node" do
      message = error_message(fn -> UI.validate(:not_a_node) end)
      assert message =~ "native node must be a LiveCimgui.UI.Node, got :not_a_node"
      assert message =~ "at <root>"

      message = error_message(fn -> UI.validate(nil) end)
      assert message =~ "got nil"
    end

    test "rejects a widget id that is not a binary, is empty, or has an incarnation below 1" do
      message =
        error_message(fn ->
          UI.validate(%Node{kind: :button, id: 42, incarnation: 1, label: "Go", event: "go"})
        end)

      assert message =~ "widget id must be a string, got 42"
      assert message =~ "at <root>"

      assert error_message(fn -> UI.validate(UI.input("", "value")) end) =~
               "widget id must not be empty"

      assert error_message(fn -> UI.validate(UI.button("", "Go")) end) =~
               "widget id must not be empty"

      message = error_message(fn -> UI.validate(UI.input("name", "value", incarnation: 0)) end)
      assert message =~ "widget incarnation must be a positive integer, got 0"

      message =
        error_message(fn -> UI.validate(%Node{kind: :input, id: "name", value: "v"}) end)

      assert message =~ "widget incarnation must be a positive integer, got nil"
    end

    test "rejects children on a leaf" do
      message =
        error_message(fn ->
          UI.validate(%Node{kind: :text, text: "x", children: [UI.text("y")]})
        end)

      assert message =~ "text cannot have children"
      assert message =~ "at <root>"

      node = %Node{kind: :button, id: "go", incarnation: 1, label: "Go", event: "go"}
      message = error_message(fn -> UI.validate(%{node | children: [UI.text("y")]}) end)
      assert message =~ "button cannot have children"

      message =
        error_message(fn -> UI.validate(%Node{kind: :diagnostics, children: [UI.text("y")]}) end)

      assert message =~ "diagnostics cannot have children"
    end

    test "rejects a non-node child in a row or column" do
      message = error_message(fn -> UI.validate(UI.row(["oops"])) end)
      assert message =~ ~s(native node must be a LiveCimgui.UI.Node, got "oops")
      assert message =~ "at <root>/0"

      message =
        error_message(fn -> UI.validate(%Node{kind: :column, children: [UI.text("a"), 42]}) end)

      assert message =~ "got 42"
      assert message =~ "at <root>/1"
    end

    test "rejects duplicate widget ids naming the id and the path" do
      message =
        error_message(fn ->
          UI.validate(
            UI.keyed("rows", [{"a", 1, UI.input("dup", "1")}, {"b", 1, UI.input("dup", "2")}])
          )
        end)

      assert message =~ ~s(duplicate widget id "dup")
      assert message =~ "at <root>/keyed(\"rows\")[1]/key(\"b\")"
    end

    test "rejects too many children" do
      message =
        error_message(fn -> UI.validate(UI.row(List.duplicate(UI.text("x"), 1_025))) end)

      assert message =~ "row has 1025 children, limit is 1024"
      assert message =~ "at <root>"

      message =
        error_message(fn ->
          UI.validate(UI.keyed("rows", List.duplicate({"a", UI.text("x")}, 1_025)))
        end)

      assert message =~ ~s(keyed collection has 1025 children, limit is 1024)
      assert message =~ ~s(at <root>)
    end

    test "rejects nesting deeper than limits().depth" do
      too_deep = Enum.reduce(1..64, UI.text("x"), fn _, inner -> UI.column([inner]) end)
      message = error_message(fn -> UI.validate(too_deep) end)

      assert message =~ "native tree exceeds 64 levels"
      assert message =~ "at <root>/0/0"
    end

    test "rejects more nodes than limits().nodes" do
      inner = fn prefix ->
        UI.keyed("inner", Enum.map(1..1_024, fn i -> {"#{prefix}/#{i}", UI.text("x")} end))
      end

      too_many = UI.keyed("outer", Enum.map(1..4, fn i -> {"o#{i}", inner.(i)} end))
      message = error_message(fn -> UI.validate(too_many) end)

      assert message =~ "native tree exceeds 4096 nodes"
      assert message =~ "at <root>/keyed(\"outer\")[3]"
    end

    test "rejects over-long text, values, events, ids, and collection keys" do
      long = fn limit -> String.duplicate("x", limit + 1) end

      assert error_message(fn -> UI.validate(UI.text(long.(65_536))) end) =~
               "text content is 65537 bytes, limit is 65536"

      assert error_message(fn -> UI.validate(UI.input("name", long.(65_536))) end) =~
               "input value is 65537 bytes, limit is 65536"

      assert error_message(fn -> UI.validate(UI.button("go", long.(65_536))) end) =~
               "button label is 65537 bytes, limit is 65536"

      assert error_message(fn -> UI.validate(UI.button("go", "Go", event: long.(256))) end) =~
               "button event is 257 bytes, limit is 256"

      assert error_message(fn -> UI.validate(UI.input(long.(256), "value")) end) =~
               "widget id is 257 bytes, limit is 256"

      assert error_message(fn -> UI.validate(UI.keyed(long.(256), [])) end) =~
               "keyed collection key is 257 bytes, limit is 256"
    end

    test "rejects duplicate keyed child keys and non-binary keys" do
      message =
        error_message(fn ->
          UI.validate(UI.keyed("rows", [{"a", UI.text("1")}, {"a", UI.text("2")}]))
        end)

      assert message =~ ~s(duplicate keyed child key "a")
      assert message =~ "at <root>/keyed(\"rows\")"

      message = error_message(fn -> UI.validate(%Node{kind: :keyed, key: :bad, children: []}) end)
      assert message =~ "keyed collection key must be a string, got :bad"

      message =
        error_message(fn -> UI.validate(%Node{kind: :keyed, key: "rows", children: "no"}) end)

      assert message =~ "keyed children must be a list, got \"no\""
    end

    test "rejects malformed keyed children" do
      # A child that is not {key, incarnation, node}.
      message =
        error_message(fn ->
          UI.validate(%Node{kind: :keyed, key: "rows", children: [{"a", UI.text("A")}]})
        end)

      assert message =~ "keyed child must be {key, incarnation, node}"
      assert message =~ "at <root>[0]"

      message =
        error_message(fn ->
          UI.validate(%Node{kind: :keyed, key: "rows", children: [UI.text("A")]})
        end)

      assert message =~ "keyed child must be {key, incarnation, node}"

      message =
        error_message(fn ->
          UI.validate(%Node{
            kind: :keyed,
            key: "rows",
            children: [{"a", 1, UI.text("A"), :extra}]
          })
        end)

      assert message =~ "keyed child must be {key, incarnation, node}"

      # A well-shaped child whose third element is not a node.
      message =
        error_message(fn ->
          UI.validate(%Node{kind: :keyed, key: "rows", children: [{"a", "not a node"}]})
        end)

      assert message =~ "keyed child must be {key, incarnation, node}"

      message =
        error_message(fn ->
          UI.validate(%Node{kind: :keyed, key: "rows", children: [{"a", 1, "not a node"}]})
        end)

      assert message =~ ~s(keyed child must be a LiveCimgui.UI.Node, got "not a node")
      assert message =~ "at <root>[0]"

      # Incarnations stay positive integers.
      message =
        error_message(fn ->
          UI.validate(%Node{kind: :keyed, key: "rows", children: [{"a", 0, UI.text("x")}]})
        end)

      assert message =~ "keyed child incarnation must be a positive integer, got 0"
      assert message =~ "at <root>[0]"

      message =
        error_message(fn ->
          UI.validate(%Node{kind: :keyed, key: "rows", children: [{"a", "x", UI.text("y")}]})
        end)

      assert message =~ ~s(keyed child incarnation must be a positive integer, got "x")
      assert message =~ "at <root>[0]"
    end
  end

  describe "widgets/1 and diagnostics/0" do
    test "widgets/1 returns every {id, incarnation} in render order" do
      tree =
        UI.column([
          UI.text("t"),
          UI.keyed("outer", [
            {"o1", 7,
             UI.keyed("inner", [{"i1", 2, UI.input("deep", "v")}, {"i2", UI.button("bb", "B")}])},
            {"o2", UI.input("second", "w")}
          ]),
          UI.row([UI.button("last", "L")]),
          UI.diagnostics()
        ])

      assert UI.widgets(tree) == [{"deep", 1}, {"bb", 1}, {"second", 1}, {"last", 1}]
      assert UI.widgets(UI.text("t")) == []
      assert UI.widgets(UI.diagnostics()) == []
      assert UI.widgets(UI.keyed("rows", [])) == []

      assert UI.widgets(
               UI.keyed("rows", [
                 {"a", UI.input("first", "1")},
                 {"b", 4, UI.button("second", "2", incarnation: 4)}
               ])
             ) == [{"first", 1}, {"second", 4}]
    end

    test "diagnostics/0 has no id and no children" do
      assert UI.diagnostics() == %Node{kind: :diagnostics, id: nil, children: []}
      assert %Node{id: nil, children: []} = UI.diagnostics()
      assert {:ok, _node} = UI.validate(UI.diagnostics())
    end
  end

  describe "keyed identity rules" do
    test "rejects empty, over-long, and non-binary keyed child keys" do
      message =
        error_message(fn ->
          UI.validate(UI.keyed("rows", [{"", UI.text("x")}]))
        end)

      assert message =~ "keyed child key must not be empty"
      assert message =~ "at <root>[0]"

      message =
        error_message(fn ->
          UI.validate(UI.keyed("rows", [{String.duplicate("k", 300), UI.text("x")}]))
        end)

      assert message =~ "keyed child key is 300 bytes, limit is 256"
      assert message =~ "at <root>[0]"

      message =
        error_message(fn ->
          UI.validate(%Node{
            kind: :keyed,
            key: "rows",
            children: [{:not_a_string, 1, UI.text("A")}]
          })
        end)

      assert message =~ "keyed child key must be a string, got :not_a_string"
      assert message =~ "at <root>[0]"

      # A 2-tuple whose key is not a binary is not one of the accepted shapes at all.
      message =
        error_message(fn ->
          UI.validate(%Node{kind: :keyed, key: "rows", children: [{:not_a_string, UI.text("A")}]})
        end)

      assert message =~ "keyed child must be {key, incarnation, node}, got {:not_a_string,"
      assert message =~ "at <root>[0]"
    end

    test "rejects an empty keyed collection key" do
      message = error_message(fn -> UI.validate(%Node{kind: :keyed, key: "", children: []}) end)
      assert message =~ "keyed collection key must not be empty"
      assert message =~ "at <root>"

      message = error_message(fn -> UI.validate(UI.keyed("", [])) end)
      assert message =~ "keyed collection key must not be empty"
    end

    test "keyed/2 raises LiveCimgui.UI.Error when the collection key or a child is malformed" do
      assert_raise Error, ~r/keyed collection key must be a string, got 1/, fn ->
        UI.keyed(1, [])
      end

      assert_raise Error, ~r/keyed collection key must be a string, got :not_a_string/, fn ->
        UI.keyed(:not_a_string, [])
      end

      assert_raise Error, ~r/is not a valid keyed collection/, fn -> UI.keyed(nil, nil) end

      assert_raise Error, ~r/keyed "k" children must be a list/, fn ->
        UI.keyed("k", "not a list")
      end

      assert_raise Error,
                   ~r/keyed child must be \{key, node\} or \{key, incarnation, node\}/,
                   fn ->
                     UI.keyed("k", ["nope"])
                   end

      assert_raise Error,
                   ~r/keyed child must be \{key, node\} or \{key, incarnation, node\}/,
                   fn ->
                     UI.keyed("k", [{:not_a_string, UI.text("A")}])
                   end

      # The valid forms still construct.
      assert UI.keyed("k", []) == %Node{kind: :keyed, key: "k", children: []}
      assert UI.keyed("k", [{"a", UI.text("A")}]).children == [{"a", 1, UI.text("A")}]
      assert UI.keyed("k", [{"a", 3, UI.text("A")}]).children == [{"a", 3, UI.text("A")}]
    end
  end
end
