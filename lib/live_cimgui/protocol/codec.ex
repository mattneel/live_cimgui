defmodule LiveCimgui.Protocol.Codec do
  @moduledoc false
  # Message bodies for the wire protocol. This module is the reference
  # implementation of `docs/PROTOCOL.md`; the Zig host implements the same
  # rules, and `LiveCimgui.ProtocolTest`/`LiveCimgui.ProtocolRandomTest` pin
  # both directions.

  # Protocol is only needed by callers of this codec.
  alias LiveCimgui.Protocol.Reader
  alias LiveCimgui.Protocol.Writer
  alias LiveCimgui.UI.Node

  @max_text_bytes 65_536
  @max_id_bytes 256
  @max_title_bytes 256
  @max_path_bytes 512
  @max_nodes 4_096
  @max_depth 64
  @max_children 1_024

  @type_codes %{
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
  @type_names Map.new(@type_codes, fn {name, code} -> {code, name} end)

  @node_tags %{text: 1, button: 2, input: 3, row: 4, column: 5, keyed: 6, diagnostics: 7}

  @event_kinds %{button_click: 0, input_edit: 1, window_close: 2, input_submit: 3}

  @shutdown_reasons %{normal: 0, restart: 1}

  @overload_codes %{
    outbound_full: 0,
    command_full: 1,
    draft_full: 2,
    frame_oversized: 3,
    unknown_message: 4,
    stale_session: 5,
    stale_generation: 6,
    stale_incarnation: 7,
    stale_revision: 8,
    malformed_frame: 9
  }
  @overload_names Map.new(@overload_codes, fn {name, code} -> {code, name} end)

  @faults %{stall: 0, crash: 1, exit: 2}

  @mouse_kinds %{move: 0, click: 1, release: 2}

  @test_input_kinds %{text: 0, key: 1, focus: 2, mouse: 3, capture: 4}

  @doc "Encodes a message body, returning `{:ok, type_code, body}`."
  @spec encode(tuple()) :: {:ok, non_neg_integer(), binary()} | {:error, term()}
  def encode(message) do
    with {:ok, name, body} <- encode_body(message) do
      {:ok, Map.fetch!(@type_codes, name), Writer.to_binary(body)}
    end
  end

  @doc "Decodes a message body of the given numeric type code."
  @spec decode(non_neg_integer(), binary()) :: {:ok, tuple()} | {:error, term()}
  def decode(type_code, body) do
    case Map.fetch(@type_names, type_code) do
      {:ok, name} -> decode_body(name, body)
      :error -> {:error, {:unknown_type, type_code}}
    end
  end

  @doc false
  @spec type_code(atom()) :: non_neg_integer() | nil
  def type_code(name), do: Map.get(@type_codes, name)

  @doc false
  @spec type_name(non_neg_integer()) :: atom() | nil
  def type_name(code), do: Map.get(@type_names, code)

  ## Elixir -> host

  defp encode_body({:hello, session_id, view_generation, host_generation, title, width, height}) do
    with {:ok, session_id} <- limit(session_id, @max_id_bytes, :session_id),
         {:ok, title} <- limit(title, @max_title_bytes, :window_title),
         {:ok, view_generation} <- u64(view_generation, :view_generation),
         {:ok, host_generation} <- u64(host_generation, :host_generation),
         {:ok, width} <- u32(width, :width),
         {:ok, height} <- u32(height, :height) do
      {:ok, :hello,
       [
         Writer.string(session_id),
         Writer.u64(view_generation),
         Writer.u64(host_generation),
         Writer.string(title),
         Writer.u32(width),
         Writer.u32(height)
       ]}
    end
  end

  defp encode_body({:hello, _session_id, _view_generation, _host_generation, _title}),
    do: {:error, {:invalid_message, :hello_requires_window_size}}

  defp encode_body({:snapshot, view_generation, ui_revision, %Node{} = tree}) do
    with {:ok, view_generation} <- u64(view_generation, :view_generation),
         {:ok, ui_revision} <- u64(ui_revision, :ui_revision),
         {:ok, tree} <- encode_tree(tree) do
      {:ok, :snapshot, [Writer.u64(view_generation), Writer.u64(ui_revision), tree]}
    end
  end

  defp encode_body({:snapshot, _vg, _rev, other}), do: {:error, {:invalid_node, other}}

  defp encode_body({:ack, view_generation, id, incarnation, acked_revision}) do
    with {:ok, view_generation} <- u64(view_generation, :view_generation),
         {:ok, id} <- limit(id, @max_id_bytes, :widget_id),
         {:ok, incarnation} <- u64(incarnation, :incarnation),
         {:ok, acked_revision} <- u64(acked_revision, :acked_revision) do
      {:ok, :ack,
       [
         Writer.u64(view_generation),
         Writer.string(id),
         Writer.u64(incarnation),
         Writer.u64(acked_revision)
       ]}
    end
  end

  defp encode_body({:set_value, view_generation, id, incarnation, base_revision, text}) do
    with {:ok, view_generation} <- u64(view_generation, :view_generation),
         {:ok, id} <- limit(id, @max_id_bytes, :widget_id),
         {:ok, incarnation} <- u64(incarnation, :incarnation),
         {:ok, base_revision} <- u64(base_revision, :base_revision),
         {:ok, text} <- limit(text, @max_text_bytes, :text) do
      {:ok, :set_value,
       [
         Writer.u64(view_generation),
         Writer.string(id),
         Writer.u64(incarnation),
         Writer.u64(base_revision),
         Writer.string(text)
       ]}
    end
  end

  defp encode_body({:set_value, _id, _incarnation, _base_revision, _text}),
    do: {:error, {:invalid_message, :set_value_requires_view_generation}}

  defp encode_body({:inspect, request_id}) do
    with {:ok, request_id} <- u64(request_id, :request_id),
         do: {:ok, :inspect, Writer.u64(request_id)}
  end

  defp encode_body({:ping, request_id}) do
    with {:ok, request_id} <- u64(request_id, :request_id),
         do: {:ok, :ping, Writer.u64(request_id)}
  end

  defp encode_body({:shutdown, reason}) when is_map_key(@shutdown_reasons, reason),
    do: {:ok, :shutdown, Writer.u8(Map.fetch!(@shutdown_reasons, reason))}

  defp encode_body({:shutdown, reason}), do: {:error, {:unknown_reason, reason}}

  defp encode_body({:fault, kind}) when is_map_key(@faults, kind),
    do: {:ok, :fault, Writer.u8(Map.fetch!(@faults, kind))}

  defp encode_body({:fault, kind}), do: {:error, {:unknown_fault, kind}}

  defp encode_body({:test_input, :text, text}) do
    with {:ok, text} <- limit(text, @max_text_bytes, :text) do
      {:ok, :test_input, [Writer.u8(@test_input_kinds.text), Writer.string(text)]}
    end
  end

  defp encode_body({:test_input, :key, {keycode, down?}})
       when is_integer(keycode) and is_boolean(down?) do
    {:ok, :test_input,
     [Writer.u8(@test_input_kinds.key), Writer.u32(keycode), Writer.bool(down?)]}
  end

  defp encode_body({:test_input, :focus, focused?}) when is_boolean(focused?) do
    {:ok, :test_input, [Writer.u8(@test_input_kinds.focus), Writer.bool(focused?)]}
  end

  defp encode_body({:test_input, :mouse, {kind, x, y}})
       when is_map_key(@mouse_kinds, kind) and is_number(x) and is_number(y) do
    {:ok, :test_input,
     [
       Writer.u8(@test_input_kinds.mouse),
       Writer.u8(Map.fetch!(@mouse_kinds, kind)),
       Writer.f64(x),
       Writer.f64(y)
     ]}
  end

  # Test-only: ask the host to write the next frame to this path as a PPM file.
  # Used by the GUI acceptance tests, which have no other way to get pixels out
  # of a window in an environment without a window manager (docs/TESTING.md).
  defp encode_body({:test_input, :capture, path}) when is_binary(path) do
    with {:ok, path} <- limit(path, @max_path_bytes, :path) do
      {:ok, :test_input, [Writer.u8(@test_input_kinds.capture), Writer.string(path)]}
    end
  end

  defp encode_body({:test_input, kind, payload}),
    do: {:error, {:invalid_test_input, {kind, payload}}}

  defp encode_body(other), do: {:error, {:invalid_message, other}}

  ## Host -> Elixir

  defp decode_body(:hello, body) do
    with {:ok, session_id, rest} <- Reader.string(body, @max_id_bytes),
         {:ok, view_generation, rest} <- Reader.u64(rest),
         {:ok, host_generation, rest} <- Reader.u64(rest),
         {:ok, title, rest} <- Reader.string(rest, @max_title_bytes),
         {:ok, width, rest} <- Reader.u32(rest),
         {:ok, height, rest} <- Reader.u32(rest),
         :ok <- Reader.done(rest) do
      {:ok, {:hello, session_id, view_generation, host_generation, title, width, height}}
    end
  end

  defp decode_body(:snapshot, body) do
    with {:ok, view_generation, rest} <- Reader.u64(body),
         {:ok, ui_revision, rest} <- Reader.u64(rest),
         {:ok, tree, rest, _count} <- decode_tree(rest, 1, 0),
         :ok <- Reader.done(rest) do
      {:ok, {:snapshot, view_generation, ui_revision, tree}}
    end
  end

  defp decode_body(:ack, body) do
    with {:ok, view_generation, rest} <- Reader.u64(body),
         {:ok, id, rest} <- Reader.string(rest, @max_id_bytes),
         {:ok, incarnation, rest} <- Reader.u64(rest),
         {:ok, acked_revision, rest} <- Reader.u64(rest),
         :ok <- Reader.done(rest) do
      {:ok, {:ack, view_generation, id, incarnation, acked_revision}}
    end
  end

  defp decode_body(:set_value, body) do
    with {:ok, view_generation, rest} <- Reader.u64(body),
         {:ok, id, rest} <- Reader.string(rest, @max_id_bytes),
         {:ok, incarnation, rest} <- Reader.u64(rest),
         {:ok, base_revision, rest} <- Reader.u64(rest),
         {:ok, text, rest} <- Reader.string(rest, @max_text_bytes),
         :ok <- Reader.done(rest) do
      {:ok, {:set_value, view_generation, id, incarnation, base_revision, text}}
    end
  end

  defp decode_body(:inspect, body) do
    with {:ok, request_id, rest} <- Reader.u64(body),
         :ok <- Reader.done(rest),
         do: {:ok, {:inspect, request_id}}
  end

  defp decode_body(:ping, body) do
    with {:ok, request_id, rest} <- Reader.u64(body),
         :ok <- Reader.done(rest),
         do: {:ok, {:ping, request_id}}
  end

  for {name, code} <- @shutdown_reasons do
    defp decode_body(:shutdown, <<unquote(code)::8>>), do: {:ok, {:shutdown, unquote(name)}}
  end

  defp decode_body(:shutdown, <<code::8>>), do: {:error, {:unknown_reason_code, code}}

  defp decode_body(:shutdown, _body), do: {:error, {:truncated, :shutdown}}

  for {name, code} <- @faults do
    defp decode_body(:fault, <<unquote(code)::8>>), do: {:ok, {:fault, unquote(name)}}
  end

  defp decode_body(:fault, <<code::8>>), do: {:error, {:unknown_fault_code, code}}

  defp decode_body(:fault, _body), do: {:error, {:truncated, :fault}}

  defp decode_body(:test_input, <<kind::8, rest::binary>>) do
    case kind do
      0 -> decode_test_text(rest)
      1 -> decode_test_key(rest)
      2 -> decode_test_focus(rest)
      3 -> decode_test_mouse(rest)
      4 -> decode_test_capture(rest)
      other -> {:error, {:invalid_test_input, other}}
    end
  end

  defp decode_body(:test_input, _body), do: {:error, {:truncated, :test_input}}

  defp decode_body(:ready, body) do
    with {:ok, session_id, rest} <- Reader.string(body, @max_id_bytes),
         {:ok, host_generation, rest} <- Reader.u64(rest),
         {:ok, view_generation, rest} <- Reader.u64(rest),
         {:ok, sdl_version, rest} <- Reader.string(rest, @max_title_bytes),
         {:ok, gl_renderer, rest} <- Reader.string(rest, @max_title_bytes),
         {:ok, gl_version, rest} <- Reader.string(rest, @max_title_bytes),
         {:ok, pid, rest} <- Reader.u64(rest),
         :ok <- Reader.done(rest) do
      {:ok,
       {:ready,
        %{
          session_id: session_id,
          host_generation: host_generation,
          view_generation: view_generation,
          sdl_version: sdl_version,
          gl_renderer: gl_renderer,
          gl_version: gl_version,
          pid: pid
        }}}
    end
  end

  defp decode_body(:event, body) do
    with {:ok, view_generation, rest} <- Reader.u64(body),
         {:ok, ui_revision, rest} <- Reader.u64(rest) do
      decode_event_message(view_generation, ui_revision, rest)
    end
  end

  defp decode_body(:diagnostics, body) do
    with {:ok, frame_count, rest} <- Reader.u64(body),
         {:ok, applied_ui_revision, rest} <- Reader.u64(rest),
         {:ok, view_generation, rest} <- Reader.u64(rest),
         {:ok, focus_id, rest} <- Reader.string(rest, @max_id_bytes),
         {:ok, count, rest} <- Reader.u32(rest),
         {:ok, drafts, rest} <- decode_draft_summaries(rest, count, []),
         {:ok, outbound_queue, rest} <- Reader.u32(rest),
         {:ok, overloads, rest} <- Reader.u64(rest),
         {:ok, dropped_commands, rest} <- Reader.u64(rest),
         {:ok, uptime_ms, rest} <- Reader.u64(rest),
         {:ok, window_width, rest} <- Reader.u32(rest),
         {:ok, window_height, rest} <- Reader.u32(rest),
         {:ok, framebuffer_scale, rest} <- Reader.f64(rest),
         :ok <- Reader.done(rest) do
      {:ok,
       {:diagnostics,
        %{
          frame_count: frame_count,
          applied_ui_revision: applied_ui_revision,
          view_generation: view_generation,
          focus_id: focus_id,
          drafts: drafts,
          window_width: window_width,
          window_height: window_height,
          framebuffer_scale: framebuffer_scale,
          outbound_queue: outbound_queue,
          overloads: overloads,
          dropped_commands: dropped_commands,
          uptime_ms: uptime_ms
        }}}
    end
  end

  defp decode_body(:overload, body) do
    with {:ok, code, rest} <- Reader.u8(body),
         {:ok, dropped, rest} <- Reader.u64(rest),
         {:ok, queue, rest} <- Reader.u8(rest),
         {:ok, detail, rest} <- Reader.string(rest, @max_text_bytes),
         :ok <- Reader.done(rest) do
      case Map.fetch(@overload_names, code) do
        {:ok, name} ->
          {:ok, {:overload, %{code: name, dropped: dropped, queue: queue, detail: detail}}}

        :error ->
          {:error, {:unknown_overload_code, code}}
      end
    end
  end

  defp decode_body(:inspect_result, body) do
    with {:ok, request_id, rest} <- Reader.u64(body),
         {:ok, frame_count, rest} <- Reader.u64(rest),
         {:ok, applied_ui_revision, rest} <- Reader.u64(rest),
         {:ok, view_generation, rest} <- Reader.u64(rest),
         {:ok, focus_id, rest} <- Reader.string(rest, @max_id_bytes),
         {:ok, count, rest} <- Reader.u32(rest),
         {:ok, widgets, rest} <- decode_widgets(rest, count, []),
         {:ok, rect_count, rest} <- Reader.u32(rest),
         {:ok, rects, rest} <- decode_rects(rest, rect_count, []),
         {:ok, uptime_ms, rest} <- Reader.u64(rest),
         :ok <- Reader.done(rest) do
      {:ok,
       {:inspect_result,
        %{
          request_id: request_id,
          frame_count: frame_count,
          applied_ui_revision: applied_ui_revision,
          view_generation: view_generation,
          focus_id: focus_id,
          widgets: widgets,
          rects: rects,
          uptime_ms: uptime_ms
        }}}
    end
  end

  defp decode_body(:drafts, body) do
    with {:ok, view_generation, rest} <- Reader.u64(body),
         {:ok, count, rest} <- Reader.u32(rest),
         {:ok, drafts, rest} <- decode_full_drafts(rest, count, []),
         :ok <- Reader.done(rest) do
      {:ok, {:drafts, view_generation, drafts}}
    end
  end

  defp decode_body(:pong, body) do
    with {:ok, request_id, rest} <- Reader.u64(body),
         :ok <- Reader.done(rest),
         do: {:ok, {:pong, request_id}}
  end

  defp decode_body(:bye, body) do
    with {:ok, code, rest} <- Reader.u8(body),
         {:ok, detail, rest} <- Reader.string(rest, @max_text_bytes),
         :ok <- Reader.done(rest) do
      {:ok, {:bye, %{code: code, detail: detail}}}
    end
  end

  defp decode_body(:protocol_error, body) do
    with {:ok, code, rest} <- Reader.u8(body),
         {:ok, detail, rest} <- Reader.string(rest, @max_text_bytes),
         :ok <- Reader.done(rest) do
      {:ok, {:protocol_error, %{code: code, detail: detail}}}
    end
  end

  @spec decode_event_message(non_neg_integer(), non_neg_integer(), binary()) ::
          {:ok, tuple()} | {:error, term()}
  defp decode_event_message(view_generation, ui_revision, rest) do
    case decode_event(rest) do
      {:ok, event} -> {:ok, {:event, view_generation, ui_revision, event}}
      {:error, reason} -> {:error, reason}
    end
  end

  ## Decoding helpers

  @spec decode_test_text(binary()) :: {:ok, tuple()} | {:error, term()}
  defp decode_test_text(body) do
    with {:ok, text, rest} <- Reader.string(body, @max_text_bytes), :ok <- Reader.done(rest) do
      {:ok, {:test_input, :text, text}}
    end
  end

  defp decode_test_key(<<keycode::little-32, down::8>>),
    do: {:ok, {:test_input, :key, {keycode, down != 0}}}

  defp decode_test_key(_body), do: {:error, {:truncated, :test_key}}

  defp decode_test_focus(<<focused::8>>), do: {:ok, {:test_input, :focus, focused != 0}}
  defp decode_test_focus(_body), do: {:error, {:truncated, :test_focus}}

  for {name, code} <- @mouse_kinds do
    defp decode_test_mouse(<<unquote(code)::8, x::little-float-64, y::little-float-64>>),
      do: {:ok, {:test_input, :mouse, {unquote(name), x, y}}}
  end

  defp decode_test_mouse(<<code::8, _x::little-float-64, _y::little-float-64>>),
    do: {:error, {:invalid_test_input, {:mouse, code}}}

  defp decode_test_mouse(_body), do: {:error, {:truncated, :test_mouse}}

  defp decode_test_capture(body) do
    with {:ok, path, rest} <- Reader.string(body, @max_path_bytes), :ok <- Reader.done(rest) do
      {:ok, {:test_input, :capture, path}}
    end
  end

  @spec decode_event(binary()) :: {:ok, tuple()} | {:error, term()}
  for {name, code} <- @event_kinds do
    defp decode_event(<<unquote(code)::8, rest::binary>>),
      do: decode_event_kind(unquote(name), rest)
  end

  defp decode_event(<<code::8, _rest::binary>>), do: {:error, {:invalid_event_kind, code}}
  defp decode_event(_body), do: {:error, {:truncated, :event}}

  @spec decode_event_kind(:button_click | :input_edit | :input_submit | :window_close, binary()) ::
          {:ok, tuple()} | {:error, term()}
  defp decode_event_kind(:button_click, rest), do: decode_button_click(rest)
  defp decode_event_kind(:input_edit, rest), do: decode_input_edit(rest)
  defp decode_event_kind(:input_submit, rest), do: decode_input_submit(rest)

  defp decode_event_kind(:window_close, rest) do
    with :ok <- Reader.done(rest), do: {:ok, :window_close}
  end

  @spec decode_button_click(binary()) :: {:ok, tuple()} | {:error, term()}
  defp decode_button_click(body) do
    with {:ok, id, rest} <- Reader.string(body, @max_id_bytes),
         {:ok, incarnation, rest} <- Reader.u64(rest),
         {:ok, event, rest} <- Reader.string(rest, @max_id_bytes),
         :ok <- Reader.done(rest) do
      {:ok, {:button_click, id, incarnation, event}}
    end
  end

  @spec decode_input_edit(binary()) :: {:ok, tuple()} | {:error, term()}
  defp decode_input_edit(body) do
    with {:ok, id, rest} <- Reader.string(body, @max_id_bytes),
         {:ok, incarnation, rest} <- Reader.u64(rest),
         {:ok, draft_revision, rest} <- Reader.u64(rest),
         {:ok, text, rest} <- Reader.string(rest, @max_text_bytes),
         :ok <- Reader.done(rest) do
      {:ok, {:input_edit, id, incarnation, draft_revision, text}}
    end
  end

  @spec decode_input_submit(binary()) :: {:ok, tuple()} | {:error, term()}
  defp decode_input_submit(body) do
    with {:ok, id, rest} <- Reader.string(body, @max_id_bytes),
         {:ok, incarnation, rest} <- Reader.u64(rest),
         {:ok, draft_revision, rest} <- Reader.u64(rest),
         {:ok, text, rest} <- Reader.string(rest, @max_text_bytes),
         :ok <- Reader.done(rest) do
      {:ok, {:input_submit, id, incarnation, draft_revision, text}}
    end
  end

  @spec decode_draft_summaries(binary(), non_neg_integer(), [map()]) ::
          {:ok, [map()], binary()} | {:error, term()}
  defp decode_draft_summaries(body, 0, acc), do: {:ok, Enum.reverse(acc), body}

  defp decode_draft_summaries(body, count, acc) do
    with {:ok, id, rest} <- Reader.string(body, @max_id_bytes),
         {:ok, incarnation, rest} <- Reader.u64(rest),
         {:ok, draft_revision, rest} <- Reader.u64(rest),
         {:ok, ack_revision, rest} <- Reader.u64(rest) do
      entry = %{
        id: id,
        incarnation: incarnation,
        draft_revision: draft_revision,
        ack_revision: ack_revision
      }

      decode_draft_summaries(rest, count - 1, [entry | acc])
    end
  end

  @spec decode_widgets(binary(), non_neg_integer(), [map()]) ::
          {:ok, [map()], binary()} | {:error, term()}
  defp decode_widgets(body, 0, acc), do: {:ok, Enum.reverse(acc), body}

  defp decode_widgets(body, count, acc) do
    with {:ok, id, rest} <- Reader.string(body, @max_id_bytes),
         {:ok, incarnation, rest} <- Reader.u64(rest),
         {:ok, draft_revision, rest} <- Reader.u64(rest),
         {:ok, ack_revision, rest} <- Reader.u64(rest),
         {:ok, active, rest} <- Reader.u8(rest),
         {:ok, cursor, rest} <- Reader.u32(rest),
         {:ok, selection_start, rest} <- Reader.u32(rest),
         {:ok, selection_end, rest} <- Reader.u32(rest),
         {:ok, text, rest} <- Reader.string(rest, @max_text_bytes) do
      widget = %{
        id: id,
        incarnation: incarnation,
        draft_revision: draft_revision,
        ack_revision: ack_revision,
        active: active != 0,
        cursor: cursor,
        selection: {selection_start, selection_end},
        text: text
      }

      decode_widgets(rest, count - 1, [widget | acc])
    end
  end

  @spec decode_full_drafts(binary(), non_neg_integer(), [map()]) ::
          {:ok, [map()], binary()} | {:error, term()}
  @spec decode_rects(binary(), non_neg_integer(), [map()]) ::
          {:ok, [map()], binary()} | {:error, term()}
  defp decode_rects(body, 0, acc), do: {:ok, Enum.reverse(acc), body}

  defp decode_rects(body, count, acc) do
    with {:ok, id, rest} <- Reader.string(body, @max_id_bytes),
         {:ok, min_x, rest} <- Reader.f64(rest),
         {:ok, min_y, rest} <- Reader.f64(rest),
         {:ok, max_x, rest} <- Reader.f64(rest),
         {:ok, max_y, rest} <- Reader.f64(rest) do
      rect = %{id: id, min: {min_x, min_y}, max: {max_x, max_y}}
      decode_rects(rest, count - 1, [rect | acc])
    end
  end

  defp decode_full_drafts(body, 0, acc), do: {:ok, Enum.reverse(acc), body}

  defp decode_full_drafts(body, count, acc) do
    with {:ok, id, rest} <- Reader.string(body, @max_id_bytes),
         {:ok, incarnation, rest} <- Reader.u64(rest),
         {:ok, draft_revision, rest} <- Reader.u64(rest),
         {:ok, ack_revision, rest} <- Reader.u64(rest),
         {:ok, text, rest} <- Reader.string(rest, @max_text_bytes) do
      draft = %{
        id: id,
        incarnation: incarnation,
        draft_revision: draft_revision,
        ack_revision: ack_revision,
        text: text
      }

      decode_full_drafts(rest, count - 1, [draft | acc])
    end
  end

  ## Tree

  defp encode_tree(%Node{} = node) do
    case encode_node(node, 1, 0) do
      {:ok, iodata, _count} -> {:ok, iodata}
      {:error, reason} -> {:error, reason}
    end
  end

  defp encode_node(_node, depth, count) when depth > @max_depth,
    do: {:error, {:tree_too_deep, %{depth: depth, limit: @max_depth, nodes: count}}}

  defp encode_node(_node, _depth, count) when count >= @max_nodes,
    do: {:error, {:too_many_nodes, count + 1}}

  defp encode_node(%Node{kind: :text} = node, _depth, count) do
    with {:ok, text} <- limit(node.text, @max_text_bytes, :text) do
      {:ok, [Writer.u8(@node_tags.text), Writer.string(text)], count + 1}
    end
  end

  defp encode_node(%Node{kind: :button} = node, _depth, count) do
    with {:ok, id} <- limit(node.id, @max_id_bytes, :widget_id),
         {:ok, label} <- limit(node.label, @max_text_bytes, :label),
         {:ok, event} <- limit(node.event, @max_id_bytes, :event),
         {:ok, incarnation} <- u64(node.incarnation, :incarnation) do
      iodata = [
        Writer.u8(@node_tags.button),
        Writer.string(id),
        Writer.u64(incarnation),
        Writer.string(label),
        Writer.string(event)
      ]

      {:ok, iodata, count + 1}
    end
  end

  defp encode_node(%Node{kind: :input} = node, _depth, count) do
    with {:ok, id} <- limit(node.id, @max_id_bytes, :widget_id),
         {:ok, label} <- limit(node.label, @max_text_bytes, :label),
         {:ok, value} <- limit(node.value, @max_text_bytes, :text),
         {:ok, incarnation} <- u64(node.incarnation, :incarnation) do
      iodata = [
        Writer.u8(@node_tags.input),
        Writer.string(id),
        Writer.u64(incarnation),
        Writer.string(label),
        Writer.string(value)
      ]

      {:ok, iodata, count + 1}
    end
  end

  defp encode_node(%Node{kind: :diagnostics}, _depth, count),
    do: {:ok, Writer.u8(@node_tags.diagnostics), count + 1}

  defp encode_node(%Node{kind: kind, children: children}, depth, count)
       when kind in [:row, :column] do
    with :ok <- check_child_count(children),
         {:ok, inner, count} <- encode_children(children, depth, count) do
      {:ok, [Writer.u8(Map.fetch!(@node_tags, kind)), Writer.u32(length(children)), inner],
       count + 1}
    end
  end

  defp encode_node(%Node{kind: :keyed, key: key, children: children}, depth, count) do
    with {:ok, key} <- limit(key, @max_id_bytes, :key),
         :ok <- check_child_count(children),
         {:ok, inner, count} <- encode_keyed_children(children, depth, count) do
      {:ok,
       [Writer.u8(@node_tags.keyed), Writer.string(key), Writer.u32(length(children)), inner],
       count + 1}
    end
  end

  defp encode_node(other, _depth, _count), do: {:error, {:invalid_node, other}}

  defp check_decoded_children(count) when count <= @max_children, do: :ok
  defp check_decoded_children(count), do: {:error, {:too_many_children, count}}

  # Identities are validated on decode too: a hostile or corrupted peer must not
  # be able to introduce an empty id.
  defp check_identity(value, _field) when is_binary(value) and byte_size(value) > 0, do: :ok

  defp check_identity(value, field),
    do: {:error, {:invalid_identity, %{field: field, value: value}}}

  defp check_child_count(children) when is_list(children) and length(children) <= @max_children,
    do: :ok

  defp check_child_count(children),
    do: {:error, {:too_many_children, length(List.wrap(children))}}

  defp encode_children(children, depth, count) do
    Enum.reduce_while(children, {:ok, [], count}, fn child, {:ok, acc, count} ->
      case encode_node(child, depth + 1, count) do
        {:ok, iodata, count} -> {:cont, {:ok, [acc, iodata], count}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp encode_keyed_children(children, depth, count) do
    Enum.reduce_while(children, {:ok, [], count}, fn child, {:ok, acc, count} ->
      case encode_keyed_child(child, depth, count) do
        {:ok, iodata, count} -> {:cont, {:ok, [acc, iodata], count}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp encode_keyed_child({key, incarnation, child}, depth, count) do
    with {:ok, key} <- limit(key, @max_id_bytes, :key),
         {:ok, incarnation} <- u64(incarnation, :incarnation),
         {:ok, iodata, count} <- encode_node(child, depth + 1, count) do
      {:ok, [Writer.string(key), Writer.u64(incarnation), iodata], count}
    end
  end

  defp encode_keyed_child(malformed, _depth, _count),
    do: {:error, {:invalid_keyed_child, malformed}}

  defp decode_tree(_body, depth, _count) when depth > @max_depth,
    do: {:error, {:tree_too_deep, %{depth: depth, limit: @max_depth}}}

  defp decode_tree(_body, _depth, count) when count >= @max_nodes,
    do: {:error, {:too_many_nodes, count + 1}}

  for {name, code} <- @node_tags do
    defp decode_tree(<<unquote(code)::8, rest::binary>>, depth, count),
      do: decode_node(unquote(name), rest, depth, count)
  end

  defp decode_tree(<<tag::8, _rest::binary>>, _depth, _count),
    do: {:error, {:invalid_node_tag, tag}}

  defp decode_tree(_body, _depth, _count), do: {:error, {:truncated, :node}}

  defp decode_node(:text, rest, _depth, count), do: decode_leaf(rest, count, :text)
  defp decode_node(:button, rest, _depth, count), do: decode_button(rest, count)
  defp decode_node(:input, rest, _depth, count), do: decode_input(rest, count)

  defp decode_node(:diagnostics, rest, _depth, count),
    do: {:ok, %Node{kind: :diagnostics}, rest, count + 1}

  defp decode_node(kind, rest, depth, count) when kind in [:row, :column],
    do: decode_container(rest, kind, depth, count)

  defp decode_node(:keyed, rest, depth, count), do: decode_keyed(rest, depth, count)

  defp decode_leaf(body, count, :text) do
    with {:ok, text, rest} <- Reader.string(body, @max_text_bytes) do
      {:ok, %Node{kind: :text, text: text}, rest, count + 1}
    end
  end

  defp decode_button(body, count) do
    with {:ok, id, rest} <- Reader.string(body, @max_id_bytes),
         :ok <- check_identity(id, :widget_id),
         {:ok, incarnation, rest} <- Reader.u64(rest),
         {:ok, label, rest} <- Reader.string(rest, @max_text_bytes),
         {:ok, event, rest} <- Reader.string(rest, @max_id_bytes) do
      {:ok, %Node{kind: :button, id: id, incarnation: incarnation, label: label, event: event},
       rest, count + 1}
    end
  end

  defp decode_input(body, count) do
    with {:ok, id, rest} <- Reader.string(body, @max_id_bytes),
         :ok <- check_identity(id, :widget_id),
         {:ok, incarnation, rest} <- Reader.u64(rest),
         {:ok, label, rest} <- Reader.string(rest, @max_text_bytes),
         {:ok, value, rest} <- Reader.string(rest, @max_text_bytes) do
      {:ok, %Node{kind: :input, id: id, incarnation: incarnation, label: label, value: value},
       rest, count + 1}
    end
  end

  defp decode_container(body, kind, depth, count) do
    with {:ok, child_count, rest} <- Reader.u32(body),
         :ok <- check_decoded_children(child_count),
         {:ok, children, rest, count} <- decode_children(rest, child_count, depth, count, []) do
      {:ok, %Node{kind: kind, children: children}, rest, count + 1}
    end
  end

  defp decode_children(body, 0, _depth, count, acc), do: {:ok, Enum.reverse(acc), body, count}

  defp decode_children(body, remaining, depth, count, acc) do
    with {:ok, child, rest, count} <- decode_tree(body, depth + 1, count) do
      decode_children(rest, remaining - 1, depth, count, [child | acc])
    end
  end

  defp decode_keyed(body, depth, count) do
    with {:ok, key, rest} <- Reader.string(body, @max_id_bytes),
         :ok <- check_identity(key, :key),
         {:ok, child_count, rest} <- Reader.u32(rest),
         :ok <- check_decoded_children(child_count),
         {:ok, children, rest, count} <-
           decode_keyed_children(rest, child_count, depth, count, []) do
      {:ok, %Node{kind: :keyed, key: key, children: children}, rest, count + 1}
    end
  end

  defp decode_keyed_children(body, 0, _depth, count, acc),
    do: {:ok, Enum.reverse(acc), body, count}

  defp decode_keyed_children(body, remaining, depth, count, acc) do
    with {:ok, key, rest} <- Reader.string(body, @max_id_bytes),
         :ok <- check_identity(key, :key),
         {:ok, incarnation, rest} <- Reader.u64(rest),
         {:ok, child, rest, count} <- decode_tree(rest, depth + 1, count) do
      decode_keyed_children(rest, remaining - 1, depth, count, [{key, incarnation, child} | acc])
    end
  end

  ## Helpers

  defp u64(value, _field)
       when is_integer(value) and value >= 0 and value < 18_446_744_073_709_551_616,
       do: {:ok, value}

  defp u64(value, field), do: {:error, {:invalid_integer, %{field: field, value: value}}}

  defp u32(value, _field) when is_integer(value) and value >= 0 and value <= 4_294_967_295,
    do: {:ok, value}

  defp u32(value, field), do: {:error, {:invalid_integer, %{field: field, value: value}}}

  defp limit(value, limit, _field) when is_binary(value) and byte_size(value) <= limit,
    do: {:ok, value}

  defp limit(value, limit, field) when is_binary(value),
    do: {:error, {:string_too_long, %{field: field, size: byte_size(value), limit: limit}}}

  defp limit(value, _limit, field), do: {:error, {:not_a_string, %{field: field, value: value}}}

  @doc false
  @spec limits() :: map()
  def limits do
    %{
      nodes: @max_nodes,
      depth: @max_depth,
      children: @max_children,
      text_bytes: @max_text_bytes,
      id_bytes: @max_id_bytes,
      title_bytes: @max_title_bytes
    }
  end

  @doc false
  @spec overload_codes() :: %{atom() => non_neg_integer()}
  def overload_codes, do: @overload_codes

  @doc false
  @spec node_tags() :: %{atom() => non_neg_integer()}
  def node_tags, do: @node_tags

  @doc false
  @spec text_limit() :: pos_integer()
  def text_limit, do: @max_text_bytes
end
