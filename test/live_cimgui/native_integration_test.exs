defmodule LiveCimgui.NativeIntegrationTest do
  @moduledoc """
  Integration tests for the real Zigler transport (`LiveCimgui.Native`) and a
  real `live_cimgui_host` process.

  The host opens no window until it receives `hello`, and none of these tests
  ever sends one, so the whole module runs in the default `mix test` suite with
  no display. Frames are submitted immediately after `LiveCimgui.Native.open/3`
  returns — possibly before the spawned host has connected — because the
  transport must buffer them until the peer's connection is accepted
  (regression coverage for the EBADF-before-accept bug this suite reported).
  """

  use ExUnit.Case, async: false

  alias LiveCimgui.Native
  alias LiveCimgui.NativeHarness, as: Harness
  alias LiveCimgui.Protocol

  @ping_request_id 4_242

  describe "open/3" do
    test "returns a resource for the real host executable" do
      {transport, session_id} = Harness.open_transport()

      assert is_reference(transport)
      assert is_binary(session_id)
      assert is_map(Native.counters(transport))
      assert Native.counters(transport).closed == false
    end

    test "reports an error instead of raising for a nonexistent executable and leaks nothing" do
      before_children = Harness.host_children()
      before_dirs = Harness.socket_dirs()
      before_fds = Harness.fd_count()
      before_threads = Harness.thread_count()

      assert {:error, reason} = Native.open("/nonexistent/live_cimgui_host", self(), "missing")
      assert reason in [:spawn_failed, :invalid_executable]

      assert Harness.host_children() == before_children
      assert Harness.socket_dirs() == before_dirs
      assert Harness.fd_count() - before_fds <= 2
      assert Harness.thread_count() - before_threads <= 1

      # A failed open must not consume one of the bounded transport slots: a real
      # host still opens after repeated failures.
      for attempt <- 1..6 do
        assert {:error, _reason} =
                 Native.open("/nonexistent/live_cimgui_host", self(), "missing-#{attempt}")
      end

      {transport, _session_id} = Harness.open_transport()
      assert is_reference(transport)
    end
  end

  describe "submit/2 validation" do
    setup do
      {transport, session_id} = Harness.open_transport()
      %{transport: transport, session_id: session_id}
    end

    test "a ping is answered with a pong delivered to the owner", %{
      transport: transport,
      session_id: session_id
    } do
      assert :ok = Native.submit(transport, Protocol.encode!({:ping, @ping_request_id}))

      assert_receive {:live_cimgui_native, ^session_id, frame}, 2_000
      assert {:ok, {:pong, @ping_request_id}} = Protocol.decode(frame)

      # No `hello` was sent, so the host never opened a window and never sent `ready`.
      refute_receive {:live_cimgui_native, ^session_id, _other}, 250
    end

    test "rejects frames that are too short, inconsistent, mis-versioned, mis-directed or oversized",
         %{transport: transport} do
      short = <<1, 2, 3>>
      size_mismatch = <<9::little-32, Protocol.version(), 6, 0, 0, 0, 0, 0, 0>>
      wrong_version = <<8::little-32, Protocol.version() + 1, 6, 0::64>>
      # Type 38 is `pong`: a host -> Elixir type in the client -> host direction.
      host_to_elixir = <<8::little-32, Protocol.version(), 38, 0::64>>

      oversized_body = :binary.copy(<<0>>, Protocol.max_frame_bytes())

      oversized =
        <<Protocol.max_frame_bytes()::little-32, Protocol.version(), 6, oversized_body::binary>>

      assert byte_size(oversized) == Protocol.max_frame_bytes() + 6
      assert Protocol.decode!(Protocol.encode!({:ping, 1})) == {:ping, 1}

      for {label, frame} <- [
            {"short", short},
            {"size mismatch", size_mismatch},
            {"wrong version", wrong_version},
            {"host-to-elixir type", host_to_elixir},
            {"oversized", oversized}
          ] do
        assert Native.submit(transport, frame) == :malformed, "#{label} was not rejected"
      end

      # Nothing crashed: the transport still carries a valid conversation.
      assert :ok = Native.submit(transport, Protocol.encode!({:ping, @ping_request_id}))
      assert_receive {:live_cimgui_native, _session_id, frame}, 2_000
      assert {:ok, {:pong, @ping_request_id}} = Protocol.decode(frame)
    end
  end

  describe "stats/1 and counters/1" do
    test "frames_in/frames_out track answered pings and the queue drains" do
      {transport, _session_id} = Harness.open_transport()

      counters = Native.counters(transport)
      assert counters.frames_in == 0
      assert counters.frames_out == 0
      assert counters.queued_frames == 0
      assert counters.closed == false

      for request_id <- 1..4 do
        assert :ok = Native.submit(transport, Protocol.encode!({:ping, request_id}))
      end

      counters =
        Harness.wait_until(
          fn ->
            current = Native.counters(transport)

            if current.frames_out >= 4 and current.frames_in >= 4 and current.queued_frames == 0,
              do: current
          end,
          "transport counters never reached 4 frames in/out"
        )

      assert counters.frames_out >= 4
      assert counters.frames_in >= 4
      assert counters.queued_bytes == 0
      assert counters.overloads == 0
      assert counters.dropped == 0
      assert counters.protocol_errors == 0

      {queued, queued_bytes, frames_in, frames_out, overloads, dropped, malformed,
       protocol_errors, closed, child_status} = Native.stats(transport)

      assert Native.counters(transport) == %{
               queued_frames: queued,
               queued_bytes: queued_bytes,
               frames_in: frames_in,
               frames_out: frames_out,
               overloads: overloads,
               dropped: dropped,
               malformed: malformed,
               protocol_errors: protocol_errors,
               closed: closed,
               child_status: child_status
             }
    end
  end

  describe "close/1" do
    test "is idempotent and refuses further submits" do
      {transport, _session_id} = Harness.open_transport()

      assert :ok = Native.submit(transport, Protocol.encode!({:ping, 1}))
      assert_receive {:live_cimgui_native, _session_id, _frame}, 2_000

      assert :ok = Native.close(transport)
      assert :ok = Native.close(transport)
      assert Native.counters(transport).closed == true

      assert :closed = Native.submit(transport, Protocol.encode!({:ping, 2}))
    end
  end

  describe "host lifetime" do
    test "a host that dies mid-conversation is reported on the owner" do
      {transport, session_id} = Harness.open_transport()

      assert :ok = Native.submit(transport, Protocol.encode!({:ping, 1}))
      assert_receive {:live_cimgui_native, ^session_id, frame}, 2_000
      assert {:ok, {:pong, 1}} = Protocol.decode(frame)

      [host_pid | _] = Harness.host_children()
      assert {_output, 0} = System.cmd("kill", ["-9", Integer.to_string(host_pid)])

      assert_receive {:live_cimgui_native_error, ^session_id, :host_gone}, 5_000
      assert :ok = Native.close(transport)

      Harness.wait_until(
        fn -> not Harness.alive_pid?(host_pid) end,
        "the killed host process #{host_pid} is still in the process table"
      )
    end

    test "five open/close cycles leak no descriptors, threads, socket directories or children" do
      before_children = Harness.host_children()
      before_dirs = Harness.socket_dirs()
      before_fds = Harness.fd_count()
      before_threads = Harness.thread_count()

      for cycle <- 1..5 do
        {transport, session_id} = Harness.open_transport("cycle-#{cycle}")

        assert :ok = Native.submit(transport, Protocol.encode!({:ping, cycle}))
        assert_receive {:live_cimgui_native, ^session_id, frame}, 2_000
        assert {:ok, {:pong, ^cycle}} = Protocol.decode(frame)

        assert :ok = Native.close(transport)
        assert Native.counters(transport).closed == true
      end

      assert Harness.host_children() == before_children
      assert Harness.socket_dirs() == before_dirs

      fd_delta = Harness.fd_count() - before_fds
      thread_delta = Harness.thread_count() - before_threads

      assert fd_delta <= 8, "file descriptors grew by #{fd_delta} over five transport cycles"
      assert thread_delta <= 4, "OS threads grew by #{thread_delta} over five transport cycles"
    end
  end
end
