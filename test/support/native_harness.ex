defmodule LiveCimgui.NativeHarness do
  @moduledoc """
  Display-independent helpers for the native boundary tests.

  These helpers drive the *real* Zigler transport and a *real*
  `live_cimgui_host` process without ever sending `hello`, so no window is
  created and no display is required.

  Tests deliberately submit frames immediately after `LiveCimgui.Native.open/3`
  returns — that is, possibly before the spawned host has connected — because
  the transport must buffer frames until the peer's connection is accepted
  (regression coverage for the EBADF-before-accept bug this suite reported).
  """

  alias LiveCimgui.Native

  @poll_ms 20
  @max_attempts 500

  @doc "Polls `fun` until it returns a non-nil, non-false value, else fails."
  @spec wait_until((-> term()), String.t()) :: term()
  def wait_until(fun, message), do: wait_until(fun, message, @max_attempts)

  @doc "Polls `fun` at most `attempts` times (20 ms apart); fails with `message`."
  @spec wait_until((-> term()), String.t(), pos_integer()) :: term()
  def wait_until(fun, message, attempts) do
    poll(fun, fn -> raise ExUnit.AssertionError, message: message end, attempts)
  end

  # Comparison instead of pattern matching: a caller may pass a predicate whose
  # success typing is a single value, and clauses for other values would then be
  # unreachable.
  defp poll(fun, on_timeout, attempts) do
    value = fun.()

    if value == nil or value == false do
      if attempts <= 1 do
        on_timeout.()
      else
        Process.sleep(@poll_ms)
        poll(fun, on_timeout, attempts - 1)
      end
    else
      value
    end
  end

  @doc """
  Opens a transport to the real host and registers `close/1` cleanup for the
  test. Returns `{transport, session_id}`.
  """
  @spec open_transport(String.t() | nil) :: {Native.t(), String.t()}
  def open_transport(session_id \\ nil) do
    session_id =
      session_id || "native-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    {:ok, transport} = Native.open(Native.host_executable(), self(), session_id)
    ExUnit.Callbacks.on_exit(fn -> Native.close(transport) end)

    {transport, session_id}
  end

  @doc "OS pids of live_cimgui_host processes that are direct children of this BEAM."
  @spec host_children() :: [pid()]
  def host_children do
    beam = beam_os_pid()

    for entry <- File.ls!("/proc"),
        String.match?(entry, ~r/^\d+$/),
        pid = String.to_integer(entry),
        comm = comm(pid),
        String.starts_with?(comm, "live_cimgui_hos"),
        ppid(pid) == beam,
        do: pid
  end

  defp comm(pid) do
    case File.read("/proc/#{pid}/comm") do
      {:ok, contents} -> String.trim(contents)
      _ -> nil
    end
  end

  defp ppid(pid) do
    with {:ok, stat} <- File.read("/proc/#{pid}/stat"),
         [_, tail] <- String.split(stat, ") ", parts: 2) do
      tail |> String.split() |> Enum.at(1) |> String.to_integer()
    else
      _ -> nil
    end
  end

  @doc "Waits until no `live_cimgui_host` child of this BEAM remains."
  @spec await_no_host_children() :: :ok
  def await_no_host_children do
    wait_until(fn -> host_children() == [] end, "a native host child is still running")
    :ok
  end

  @doc "Whether `pid` is still present in the process table."
  @spec alive_pid?(pid()) :: boolean()
  def alive_pid?(pid), do: File.dir?("/proc/#{pid}")

  @doc "Number of file descriptors open in this BEAM."
  @spec fd_count() :: non_neg_integer()
  def fd_count, do: length(File.ls!("/proc/self/fd"))

  @doc "Number of OS threads in this BEAM process, or -1 when unavailable."
  @spec thread_count() :: integer()
  def thread_count do
    with {:ok, contents} <- File.read("/proc/self/status"),
         [_, count] <- Regex.run(~r/^Threads:\s+(\d+)$/m, contents) do
      String.to_integer(count)
    else
      _ -> -1
    end
  end

  @doc """
  Transport socket directories this BEAM has created and not removed.

  The transport prefers `XDG_RUNTIME_DIR` and falls back to `/tmp` (observed:
  it uses `/tmp` in this environment), so both bases are checked.
  """
  @spec socket_dirs() :: [String.t()]
  def socket_dirs do
    prefix = "live_cimgui_#{beam_os_pid()}_"

    ["/tmp", System.get_env("XDG_RUNTIME_DIR")]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn base ->
      case File.ls(base) do
        {:ok, entries} ->
          entries
          |> Enum.filter(&String.starts_with?(&1, prefix))
          |> Enum.map(&Path.join(base, &1))

        _ ->
          []
      end
    end)
    |> Enum.sort()
  end

  @doc "OS pid of this BEAM."
  @spec beam_os_pid() :: pos_integer()
  def beam_os_pid, do: System.pid() |> String.to_integer()

  @doc "Drains every message currently in the caller's mailbox."
  @spec drain_mailbox() :: :ok
  def drain_mailbox do
    receive do
      _message -> drain_mailbox()
    after
      0 -> :ok
    end
  end

  @typedoc """
  One host -> Elixir delivery: a decoded protocol message, a transport error
  reported by the NIF, or a frame that does not decode.
  """
  @type delivery ::
          {:message, String.t(), LiveCimgui.Protocol.message()}
          | {:transport_error, String.t(), atom()}
          | {:invalid_frame, String.t(), term()}

  @doc "Reads deliveries for at most `timeout` ms."
  @spec read_frames(non_neg_integer()) :: [delivery()]
  def read_frames(timeout), do: read_frames_until(fn _deliveries -> false end, timeout)

  @doc """
  Reads deliveries until `done?` holds for the deliveries read so far, or
  `timeout` ms elapse. Returns every delivery read.
  """
  @spec read_frames_until(([delivery()] -> boolean()), non_neg_integer()) :: [delivery()]
  def read_frames_until(done?, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    read_until(deadline, [], done?)
  end

  defp read_until(deadline, acc, done?) do
    deliveries = Enum.reverse(acc)

    if done?.(deliveries) do
      deliveries
    else
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:live_cimgui_native, session_id, frame} ->
          read_until(deadline, [normalize_delivery(session_id, frame) | acc], done?)

        {:live_cimgui_native_error, session_id, reason} ->
          read_until(deadline, [{:transport_error, session_id, reason} | acc], done?)
      after
        remaining -> deliveries
      end
    end
  end

  defp normalize_delivery(session_id, frame) do
    case LiveCimgui.Protocol.decode(frame) do
      {:ok, message} -> {:message, session_id, message}
      {:error, reason} -> {:invalid_frame, session_id, reason}
    end
  end
end
