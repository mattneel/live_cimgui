defmodule LiveCimgui.ProtocolTest do
  use ExUnit.Case, async: true

  alias LiveCimgui.Protocol
  alias LiveCimgui.UI
  alias LiveCimgui.UI.Node

  @types %{
    hello: 1,
    snapshot: 2,
    ack: 3,
    set_value: 4,
    inspect: 5,
    ping: 6,
    shutdown: 7,
    test_input: 16,
    fault: 17,
    ready: 32,
    event: 33,
    diagnostics: 34,
    overload: 35,
    inspect_result: 36,
    drafts: 37,
    pong: 38,
    bye: 39,
    protocol_error: 40
  }

  defp frame(type, body) do
    <<byte_size(body)::little-32, Protocol.version()::8, type::8, body::binary>>
  end

  describe "protocol constants" do
    test "version/0, max_frame_bytes/0, max_text_bytes/0, and max_id_bytes/0 pin the constants" do
      assert Protocol.version() == 1
      assert Protocol.max_frame_bytes() == 1_048_576
      assert Protocol.max_text_bytes() == 65_536
      assert Protocol.max_id_bytes() == 256
    end

    test "limits/0 aggregates the codec limits with the frame limit" do
      assert Protocol.limits() == %{
               nodes: 4_096,
               depth: 64,
               children: 1_024,
               text_bytes: 65_536,
               id_bytes: 256,
               title_bytes: 256,
               frame_bytes: 1_048_576
             }
    end
  end

  describe "type registry" do
    test "type_code/1 and type_name/1 are inverses for every documented type" do
      for {name, code} <- @types do
        assert Protocol.type_code(name) == code
        assert Protocol.type_name(code) == name
      end
    end

    test "unassigned codes and unknown names have no mapping" do
      documented = Map.values(@types)

      for code <- 0..255, code not in documented do
        assert Protocol.type_name(code) == nil
      end

      assert Protocol.type_code(:nope) == nil
      assert Protocol.type_name(-1) == nil
      assert Protocol.type_name(1_000) == nil
    end
  end

  describe "framing" do
    test "encode/1 then decode/1 returns the original message for every message shape" do
      messages = [
        {:hello, "session-1", 1, 0, "live_cimgui", 1280, 720},
        {:snapshot, 3, 9, UI.column([UI.text("title"), UI.input("name", "value")])},
        {:ack, 3, "widget", 2, 4},
        {:set_value, 5, "widget", 2, 4, "typed text"},
        {:inspect, 7},
        {:ping, 8},
        {:shutdown, :normal},
        {:shutdown, :restart},
        {:test_input, :text, "typed"},
        {:test_input, :key, {65, true}},
        {:test_input, :key, {65, false}},
        {:test_input, :focus, true},
        {:test_input, :focus, false},
        {:test_input, :mouse, {:move, 1.5, 2.5}},
        {:test_input, :mouse, {:click, 3.0, 4.0}},
        {:test_input, :mouse, {:release, 5.0, 6.0}},
        {:fault, :stall},
        {:fault, :crash},
        {:fault, :exit}
      ]

      for message <- messages do
        assert {:ok, frame} = Protocol.encode(message)
        assert Protocol.encode!(message) == frame
        assert {:ok, ^message} = Protocol.decode(frame)
      end
    end

    test "the frame header carries the body size, the protocol version, and the type code" do
      messages = [
        {:hello, "session", 3, 4, "title", 800, 600},
        {:snapshot, 1, 2, UI.text("x")},
        {:ack, 3, "widget", 2, 4},
        {:set_value, 5, "widget", 2, 4, "text"},
        {:ping, 8},
        {:test_input, :mouse, {:move, 1.5, 2.5}},
        {:shutdown, :restart}
      ]

      for message <- messages do
        frame = Protocol.encode!(message)
        <<size::little-32, version::8, type::8, body::binary>> = frame

        assert size == byte_size(body)
        assert version == Protocol.version()
        assert type == Protocol.type_code(elem(message, 0))
        assert {:ok, ^message} = Protocol.decode(frame)
      end
    end

    test "decode/1 decodes one frame and leaves following bytes to the caller" do
      frame = Protocol.encode!({:ping, 7})

      assert {:ok, {:ping, 7}} = Protocol.decode(frame)
      assert {:ok, {:ping, 7}} = Protocol.decode(frame <> <<1, 2, 3>>)
    end

    test "decode/1 returns {:more, n} for a prefix of a frame" do
      frame = Protocol.encode!({:ping, 7})
      <<declared::little-32, _::binary>> = frame
      size = byte_size(frame)

      assert declared == 8
      assert {:more, 6} = Protocol.decode(<<>>)
      assert {:more, 5} = Protocol.decode(binary_part(frame, 0, 1))
      assert {:more, 1} = Protocol.decode(binary_part(frame, 0, 5))
      assert {:more, ^declared} = Protocol.decode(binary_part(frame, 0, 6))
      assert {:more, ^declared} = Protocol.decode(binary_part(frame, 0, size - 1))

      for length <- 0..(size - 1) do
        assert {:more, _needed} = Protocol.decode(binary_part(frame, 0, length))
      end

      big = Protocol.encode!({:hello, "session", 3, 4, "title", 800, 600})

      for length <- 0..(byte_size(big) - 1) do
        assert {:more, _needed} = Protocol.decode(binary_part(big, 0, length))
      end
    end

    test "decode/1 returns {:more, n} when the body is shorter than its declared size" do
      # The declared size is reported back in full, not the number of missing bytes.
      assert {:more, 8} =
               Protocol.decode(<<8::little-32, Protocol.version()::8, 6::8, 1::little-32>>)

      assert {:more, 30} =
               Protocol.decode(<<30::little-32, Protocol.version()::8, 33::8, 0::little-64>>)
    end

    test "decode/1 rejects a declared size above max_frame_bytes/0 without allocating a body" do
      limit = Protocol.max_frame_bytes()
      declared = limit + 1

      # Only the 6-byte header exists: a decoder that sliced before validating the size
      # would have to allocate `declared` bytes first.
      header = <<declared::little-32, Protocol.version()::8, Protocol.type_code(:snapshot)::8>>

      assert {:error, {:frame_too_large, %{size: ^declared, limit: ^limit}}} =
               Protocol.decode(header)

      assert {:error, {:frame_too_large, %{size: ^declared, limit: ^limit}}} =
               Protocol.decode(header <> <<0::128>>)

      huge = 20_000_000
      header = <<huge::little-32, Protocol.version()::8, Protocol.type_code(:snapshot)::8>>

      assert {:error, {:frame_too_large, %{size: ^huge, limit: ^limit}}} =
               Protocol.decode(header <> <<0::128>>)
    end

    test "decode/1 rejects an unsupported version byte" do
      <<size::little-32, _version::8, type::8, body::binary>> = Protocol.encode!({:ping, 7})

      for version <- [0, 2, 3, 255] do
        assert {:error, {:unsupported_version, ^version}} =
                 Protocol.decode(<<size::little-32, version::8, type::8, body::binary>>)
      end
    end

    test "decode/1 rejects an unknown type code" do
      assert {:error, {:unknown_type, 99}} = Protocol.decode(<<0::little-32, 1, 99>>)
      assert {:error, {:unknown_type, 8}} = Protocol.decode(<<0::little-32, 1, 8>>)

      <<size::little-32, _::8, _type::8, body::binary>> = Protocol.encode!({:ping, 7})

      assert {:error, {:unknown_type, 99}} =
               Protocol.decode(<<size::little-32, 1, 99, body::binary>>)
    end

    test "decode!/1 and encode!/1 raise ArgumentError on invalid input" do
      assert {:ping, 7} == Protocol.decode!(Protocol.encode!({:ping, 7}))

      assert_raise ArgumentError, fn -> Protocol.decode!(<<>>) end
      assert_raise ArgumentError, fn -> Protocol.decode!(<<9::little-32, 1, 7, 9>>) end
      assert_raise ArgumentError, fn -> Protocol.decode!(frame(7, <<9>>)) end

      error = assert_raise ArgumentError, fn -> Protocol.encode!({:bogus, 1}) end
      assert error.message =~ "cannot encode message"
      assert error.message =~ "invalid_message"

      error = assert_raise ArgumentError, fn -> Protocol.encode!({:ping, :nope}) end
      assert error.message =~ "invalid_integer"
    end
  end

  describe "encoding limits" do
    test "encode/1 rejects an over-long string with the offending field, size, and limit" do
      long = fn limit -> String.duplicate("x", limit + 1) end

      assert {:error, {:string_too_long, %{field: :widget_id, size: 257, limit: 256}}} =
               Protocol.encode({:ack, 3, long.(256), 1, 1})

      assert {:error, {:string_too_long, %{field: :session_id, size: 257, limit: 256}}} =
               Protocol.encode({:hello, long.(256), 1, 2, "title", 800, 600})

      assert {:error, {:string_too_long, %{field: :window_title, size: 257, limit: 256}}} =
               Protocol.encode({:hello, "s", 1, 2, long.(256), 800, 600})

      assert {:error, {:string_too_long, %{field: :text, size: 65_537, limit: 65_536}}} =
               Protocol.encode({:test_input, :text, long.(65_536)})

      # A string exactly at the limit is accepted.
      assert {:ok, _frame} = Protocol.encode({:ack, 3, long.(255), 1, 1})
      assert {:ok, _frame} = Protocol.encode({:test_input, :text, long.(65_535)})
    end

    test "encode/1 rejects strings that are not binaries" do
      assert {:error, {:not_a_string, %{field: :widget_id, value: :widget}}} =
               Protocol.encode({:ack, 3, :widget, 1, 1})

      assert {:error, {:not_a_string, %{field: :session_id, value: 42}}} =
               Protocol.encode({:hello, 42, 1, 2, "title", 800, 600})

      assert {:error, {:not_a_string, %{field: :window_title, value: nil}}} =
               Protocol.encode({:hello, "s", 1, 2, nil, 800, 600})

      assert {:error, {:not_a_string, %{field: :text, value: 42}}} =
               Protocol.encode({:test_input, :text, 42})
    end

    test "encode/1 rejects non-integer and out-of-range revisions" do
      assert {:error, {:invalid_integer, %{field: :view_generation, value: :one}}} =
               Protocol.encode({:ack, :one, "widget", 1, 1})

      assert {:error, {:invalid_integer, %{field: :incarnation, value: 1.5}}} =
               Protocol.encode({:ack, 3, "widget", 1.5, 1})

      assert {:error, {:invalid_integer, %{field: :acked_revision, value: -1}}} =
               Protocol.encode({:ack, 3, "widget", 1, -1})

      assert {:error,
              {:invalid_integer, %{field: :request_id, value: 18_446_744_073_709_551_616}}} =
               Protocol.encode({:inspect, 18_446_744_073_709_551_616})

      assert {:error, {:invalid_integer, %{field: :width, value: 4_294_967_296}}} =
               Protocol.encode({:hello, "s", 1, 2, "title", 4_294_967_296, 600})

      # Boundary values are accepted.
      assert {:ok, _frame} = Protocol.encode({:ack, 0, "widget", 0, 18_446_744_073_709_551_615})
      assert {:ok, _frame} = Protocol.encode({:hello, "s", 0, 0, "title", 4_294_967_295, 0})
    end

    test "encode/1 rejects the hello/5 shape that omits the window size" do
      assert {:error, {:invalid_message, :hello_requires_window_size}} =
               Protocol.encode({:hello, "session", 1, 2, "title"})
    end

    test "encode/1 rejects a body larger than max_frame_bytes/0" do
      limit = Protocol.max_frame_bytes()
      texts = List.duplicate(UI.text(String.duplicate("x", 65_536)), 17)

      assert {:error, {:frame_too_large, %{size: size, limit: ^limit}}} =
               Protocol.encode({:snapshot, 0, 1, UI.row(texts)})

      assert size > limit
    end

    test "encode/1 rejects a snapshot whose tree contains something that is not a node" do
      assert {:error, {:invalid_node, "not a node"}} =
               Protocol.encode({:snapshot, 0, 0, "not a node"})

      assert {:error, {:invalid_node, %Node{kind: :slider}}} =
               Protocol.encode({:snapshot, 0, 0, %Node{kind: :slider}})

      assert {:error, {:invalid_node, 42}} = Protocol.encode({:snapshot, 0, 0, UI.row([42])})
    end

    test "encode/1 only accepts messages that travel from Elixir to the host" do
      assert {:error, {:invalid_message, {:ready, %{}}}} = Protocol.encode({:ready, %{}})
      assert {:error, {:invalid_message, {:pong, 1}}} = Protocol.encode({:pong, 1})
      assert {:error, {:invalid_message, {:bogus, 1}}} = Protocol.encode({:bogus, 1})
    end

    test "snapshot and set_value round trip" do
      tree = UI.column([UI.text("title"), UI.input("name", "value"), UI.diagnostics()])

      assert {:ok, {:snapshot, 3, 9, ^tree}} =
               Protocol.decode(Protocol.encode!({:snapshot, 3, 9, tree}))

      assert {:ok, {:snapshot, 0, 0, %LiveCimgui.UI.Node{kind: :text, text: "hi"}}} =
               Protocol.decode(Protocol.encode!({:snapshot, 0, 0, UI.text("hi")}))

      assert {:ok, {:set_value, 5, "widget", 2, 4, "text"}} =
               Protocol.decode(Protocol.encode!({:set_value, 5, "widget", 2, 4, "text"}))
    end

    test "encode/1 rejects the stale set_value shape without a view generation" do
      assert {:error, {:invalid_message, :set_value_requires_view_generation}} =
               Protocol.encode({:set_value, "widget", 2, 4, "text"})
    end
  end

  describe "classify/1" do
    test "classifies decoded application events as :event" do
      events = [
        {:button_click, "button", 3, "go"},
        {:input_edit, "widget", 3, 4, "hello"},
        {:input_submit, "widget", 3, 4, "hello"},
        :window_close
      ]

      for payload <- events do
        body = <<1::little-64, 2::little-64, payload_to_binary(payload)::binary>>

        assert {:ok, {:event, 1, 2, ^payload}} =
                 Protocol.decode(frame(Protocol.type_code(:event), body))

        assert Protocol.classify({:event, 1, 2, payload}) == :event
      end
    end

    test "classifies every non-event message as :framework" do
      messages = [
        {:hello, "session", 1, 2, "title", 800, 600},
        {:snapshot, 0, 1, UI.text("x")},
        {:ack, 3, "widget", 2, 4},
        {:inspect, 7},
        {:ping, 8},
        {:shutdown, :normal},
        {:test_input, :focus, true},
        {:fault, :stall},
        {:ready, %{}},
        {:diagnostics, %{}},
        {:overload, %{}},
        {:inspect_result, %{}},
        {:drafts, 1, []},
        {:pong, 1},
        {:bye, %{}},
        {:protocol_error, %{}},
        :not_a_message,
        nil
      ]

      for message <- messages do
        assert Protocol.classify(message) == :framework
      end
    end
  end

  defp payload_to_binary({:button_click, id, incarnation, event}) do
    <<0::8, byte_size(id)::little-32, id::binary, incarnation::little-64,
      byte_size(event)::little-32, event::binary>>
  end

  defp payload_to_binary({:input_edit, id, incarnation, draft_revision, text}) do
    <<1::8, byte_size(id)::little-32, id::binary, incarnation::little-64,
      draft_revision::little-64, byte_size(text)::little-32, text::binary>>
  end

  defp payload_to_binary({:input_submit, id, incarnation, draft_revision, text}) do
    <<3::8, byte_size(id)::little-32, id::binary, incarnation::little-64,
      draft_revision::little-64, byte_size(text)::little-32, text::binary>>
  end

  defp payload_to_binary(:window_close), do: <<2::8>>
end
