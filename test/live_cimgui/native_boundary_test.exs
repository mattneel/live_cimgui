defmodule LiveCimgui.NativeBoundaryTest do
  @moduledoc """
  Boundary tests for the real Elixir <-> Zig transport, the protocol host, and
  `LiveCimgui.HostManager`'s session bookkeeping.

  No `hello` is ever sent to a real host, so no window is created. The
  `HostManager` test starts the manager against a minimal quiet stand-in host
  (a process that connects to the transport socket and then stays silent) so it
  can run without a display: the manager's session hygiene is independent of
  what the peer does.
  """

  use ExUnit.Case, async: false

  alias LiveCimgui.HostManager
  alias LiveCimgui.Native
  alias LiveCimgui.NativeHarness, as: Harness
  alias LiveCimgui.Protocol
  alias LiveCimgui.Protocol.Writer
  alias LiveCimgui.UI

  @stub_c """
  /* Minimal stand-in host: connect to the transport socket named by
   * `--socket <path>`, then read until the peer closes. It never opens a
   * window and never answers a frame, so a manager using it stays windowless. */
  #include <sys/socket.h>
  #include <sys/un.h>
  #include <unistd.h>
  #include <string.h>

  int main(int argc, char **argv) {
      const char *path = 0;
      int i;
      for (i = 1; i < argc; i++) {
          if (strcmp(argv[i], "--socket") == 0 && i + 1 < argc) path = argv[i + 1];
      }
      if (!path) return 2;
      int fd = socket(AF_UNIX, SOCK_STREAM, 0);
      if (fd < 0) return 3;
      struct sockaddr_un addr;
      memset(&addr, 0, sizeof addr);
      addr.sun_family = AF_UNIX;
      if (strlen(path) >= sizeof(addr.sun_path)) return 4;
      strcpy(addr.sun_path, path);
      if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) return 5;
      char buffer[4096];
      for (;;) {
          ssize_t read_bytes = read(fd, buffer, sizeof buffer);
          if (read_bytes <= 0) break;
      }
      return 0;
  }
  """

  @stub_python """
  import socket, sys, time

  path = sys.argv[sys.argv.index("--socket") + 1]
  sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
  sock.connect(path)

  while True:
      time.sleep(3600)
  """

  describe "real bridge round trip" do
    test "a LiveCimgui.UI description is accepted by the real host" do
      {transport, session_id} = Harness.open_transport()

      tree =
        UI.column([
          UI.text("boundary"),
          UI.input("draft", "hello", label: "draft"),
          UI.row([UI.button("go", "Go"), UI.button("stop", "Stop", incarnation: 2)]),
          UI.keyed("rows", [{"one", 1, UI.text("row one")}, {"two", 2, UI.text("row two")}])
        ])

      assert {:ok, ^tree} = UI.validate(tree)
      assert :ok = Native.submit(transport, Protocol.encode!({:snapshot, 1, 1, tree}))

      # A snapshot is only applied when the host's frame loop drains its inbound
      # queue, and a newer *queued* snapshot replaces an older one, so wait for
      # the host to report the widgets it installed before sending the next one.
      installed =
        Harness.read_frames_until(
          fn deliveries -> Enum.any?(deliveries, &drafts_delivery?(&1, session_id, 1)) end,
          3_000
        )

      assert Enum.any?(installed, &drafts_delivery?(&1, session_id, 1)),
             "the host never reported the widgets of the accepted description"

      # Positive evidence that the description really was installed: a snapshot
      # from an older view generation is rejected, and the rejection arrives as
      # a `stale_generation` overload through the same transport.
      assert :ok = Native.submit(transport, Protocol.encode!({:snapshot, 0, 2, tree}))

      rejections =
        Harness.read_frames_until(
          fn deliveries ->
            Enum.any?(deliveries, &overload_delivery?(&1, session_id, :stale_generation))
          end,
          3_000
        )

      for delivery <- installed ++ rejections do
        case delivery do
          {:message, ^session_id, {:protocol_error, info}} ->
            flunk(
              "the host reported a protocol error for an accepted description: #{inspect(info)}"
            )

          {:transport_error, ^session_id, reason} ->
            flunk("the transport failed while submitting a description: #{inspect(reason)}")

          {:invalid_frame, ^session_id, reason} ->
            flunk("the host sent an undecodable frame: #{inspect(reason)}")

          _other ->
            :ok
        end
      end

      assert Enum.any?(rejections, &overload_delivery?(&1, session_id, :stale_generation)),
             "the host never rejected a snapshot from an older view generation"
    end
  end

  describe "session identity" do
    test "two transports to the same owner keep their own session ids" do
      {first, first_session} = Harness.open_transport("boundary-first")
      {second, second_session} = Harness.open_transport("boundary-second")

      assert first_session == "boundary-first"
      assert second_session == "boundary-second"

      assert :ok = Native.submit(first, Protocol.encode!({:ping, 101}))
      assert :ok = Native.submit(second, Protocol.encode!({:ping, 202}))

      delivered =
        Harness.read_frames(1_500)
        |> Enum.map(fn {:message, session_id, message} -> {session_id, message} end)
        |> Enum.sort()

      assert delivered == [
               {first_session, {:pong, 101}},
               {second_session, {:pong, 202}}
             ]
    end
  end

  describe "HostManager session hygiene" do
    setup do
      %{manager: start_stub_manager!()}
    end

    test "a frame from another session is counted as stale and changes nothing", %{
      manager: manager
    } do
      before = status(manager)

      refute before.ready
      assert before.ui_revision == 0

      foreign_session = "obsolete-session"

      for _ <- 1..3 do
        send(manager, {:live_cimgui_native, foreign_session, ready_frame(foreign_session)})
      end

      send(manager, {:live_cimgui_native_error, foreign_session, :host_gone})

      after_status =
        Harness.wait_until(
          fn ->
            current = status(manager)
            if current.stale_messages >= before.stale_messages + 4, do: current
          end,
          "foreign-session messages were not counted as stale"
        )

      assert after_status.ready == false
      assert after_status.ui_revision == 0
      assert is_map(status(manager))
    end
  end

  ## Stub host

  defp drafts_delivery?(
         {:message, session_id, {:drafts, generation, _drafts}},
         expected_session,
         expected_generation
       ) do
    session_id == expected_session and generation == expected_generation
  end

  defp drafts_delivery?(_delivery, _expected_session, _expected_generation), do: false

  defp overload_delivery?(
         {:message, session_id, {:overload, %{code: code}}},
         expected_session,
         expected_code
       ) do
    session_id == expected_session and code == expected_code
  end

  defp overload_delivery?(_delivery, _expected_session, _expected_code), do: false

  # A manager owns a real transport either way; `HostManager.start_link` sends
  # `hello` immediately, so the only way to keep a window from opening (and this
  # file display-independent) is a peer that connects but never speaks the
  # protocol. The stand-in connects like a real host would (a tiny C program
  # when a compiler is available, otherwise python3) and then drains the
  # frames the manager sends, so the manager neither restarts nor opens a
  # window.
  defp start_stub_manager! do
    dir = Path.join(System.tmp_dir!(), "live_cimgui_stub_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    stub = build_stub!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, manager} =
      HostManager.start_link(
        title: "boundary-stub",
        executable: stub,
        restart_limit: 1_000,
        restart_window_ms: 600_000
      )

    on_exit(fn -> stop_manager(manager) end)
    manager
  end

  defp build_stub!(dir) do
    case System.find_executable("cc") do
      nil ->
        build_python_stub!(dir)

      cc ->
        source = Path.join(dir, "stub.c")
        binary = Path.join(dir, "host_stub")
        File.write!(source, @stub_c)

        case System.cmd(cc, ["-O2", "-o", binary, source], stderr_to_stdout: true) do
          {_output, 0} -> binary
          {_output, _status} -> build_python_stub!(dir)
        end
    end
  end

  defp build_python_stub!(dir) do
    if System.find_executable("python3") do
      stub = Path.join(dir, "host_stub")
      File.write!(Path.join(dir, "stub.py"), @stub_python)
      File.write!(stub, "#!/bin/sh\nexec python3 \"$(dirname \"$0\")/stub.py\" \"$@\"\n")
      File.chmod!(stub, 0o755)
      stub
    else
      raise "the session-hygiene test needs a stand-in host (cc or python3)"
    end
  end

  defp stop_manager(manager) do
    if Process.alive?(manager) do
      try do
        HostManager.close(manager)
      catch
        :exit, _reason -> Process.exit(manager, :kill)
      end
    end

    :ok
  end

  defp status(manager), do: status(manager, 3)

  defp status(manager, retries) do
    HostManager.status(manager)
  catch
    # A manager inside a native restart blocks in `Native.close/1` for about two
    # seconds, so a call can outlive its timeout without the manager dying.
    :exit, {:timeout, _reason} ->
      if retries > 1 do
        status(manager, retries - 1)
      else
        raise ExUnit.AssertionError, message: "the host manager stayed unresponsive to status/1"
      end

    :exit, reason ->
      raise ExUnit.AssertionError, message: "the host manager stopped: #{inspect(reason)}"
  end

  # A well-formed `ready` frame (type 32) whose body carries a foreign session.
  defp ready_frame(session_id) do
    body =
      IO.iodata_to_binary([
        Writer.string(session_id),
        Writer.u64(1),
        Writer.u64(1),
        Writer.string("SDL2"),
        Writer.string("OpenGL3"),
        Writer.string("3.3"),
        Writer.u64(9_999)
      ])

    <<byte_size(body)::little-32, Protocol.version(), 32, body::binary>>
  end
end
