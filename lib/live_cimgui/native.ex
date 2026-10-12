defmodule LiveCimgui.Native do
  @moduledoc """
  The Zigler bridge between the BEAM and one native host process.

  This module is the real Elixir↔Zig interface: `use Zig` compiles
  `native/nif/transport.zig` into a NIF, and every function below is a NIF
  generated from a `pub fn` in that file.

  ## Contract

    * `open/3` creates a UNIX listener, spawns the host executable with
      `posix_spawn`, starts one transport thread, and returns a resource. It
      acknowledges *transport* creation; the window becoming ready arrives later
      as `{:live_cimgui_native, session_id, frame}` where `frame` is a complete
      `LiveCimgui.Protocol` frame.
    * `submit/2` encodes a frame into the host's bounded outbound queue and
      acknowledges queue acceptance — never presentation. It is a short,
      bounded call on a normal scheduler.
    * `close/1` is idempotent, runs on a dirty IO scheduler, joins the transport
      thread, and reaps the host process.
    * Transport failures arrive as `{:live_cimgui_native_error, session_id, reason}`
      with `reason` in `:frame_too_large`, `:malformed_frame`,
      `:truncated_frame`, `:peer_unavailable`, `:owner_unreachable`.

  ## Ownership

  The caller (normally `LiveCimgui.HostManager`) owns the resource. The resource
  holds a reference to itself for the lifetime of the transport thread, so the
  thread can never touch freed native memory: the resource is only destroyed
  after the thread has exited and the BEAM term is unreachable.

  ## Threading

  The transport thread is a plain OS thread, not a scheduler and not a Zigler
  `:threaded` NIF. It initializes an independent BEAM environment
  (`beam.independent_context/1`) and sends messages with `enif_send/4` from that
  environment, which is the only supported way for a non-scheduler thread to
  talk to a process. Native workers are joined before the NIF is unloaded:
  `close/1` joins explicitly, and the module's `@on_load`/unload path only runs
  after every resource has been destroyed, at which point no thread remains.
  """

  use Zig,
    otp_app: :live_cimgui,
    zig_code_path: "./native/nif/transport.zig",
    # Bare atoms: `[Transport]` would expand to the Elixir module alias `Elixir.Transport`.
    resources: [:Transport],
    nifs: [
      raw_open: [alias: :open],
      raw_submit: [alias: :submit],
      raw_close: [alias: :close, concurrency: :dirty_io],
      raw_stats: [alias: :stats]
    ],
    callbacks: [on_load: :onLoad]

  @typedoc "Opaque native transport resource."
  @type t :: reference()

  @doc """
  Opens a native host.

  `executable` is the absolute path of the host binary, `owner` receives tagged
  asynchronous messages, and `session_id` identifies this host session so that
  delayed messages from an obsolete session can be rejected.
  """
  @spec open(String.t(), pid(), String.t()) :: {:ok, t()} | {:error, atom()}
  def open(executable, owner, session_id)
      when is_binary(executable) and is_pid(owner) and is_binary(session_id) do
    raw_open(executable, owner, session_id)
  end

  @doc """
  Submits one encoded frame.

  Returns `:ok` when the frame was accepted into the bounded outbound queue,
  `:overloaded` when the queue is saturated, `:closed` when the transport has
  been closed, and `:malformed` when the frame is not a valid frame.
  """
  @spec submit(t(), binary()) :: :ok | :overloaded | :closed | :malformed
  def submit(transport, frame) when is_binary(frame), do: raw_submit(transport, frame)

  @doc "Closes the transport. Idempotent; returns `:ok` for both first and repeat calls."
  @spec close(t()) :: :ok
  def close(transport), do: raw_close(transport)

  @doc """
  Raw transport counters as a tuple:

      {queued_frames, queued_bytes, frames_in, frames_out, overloads, dropped,
       malformed, protocol_errors, closed?, child_status}
  """
  @spec stats(t()) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer(),
           non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer(), boolean(),
           integer()}
  def stats(transport), do: raw_stats(transport)

  @doc "Transport counters under named keys."
  @spec counters(t()) :: map()
  def counters(transport) do
    {queued, queued_bytes, frames_in, frames_out, overloads, dropped, malformed, protocol_errors,
     closed?, child_status} = stats(transport)

    %{
      queued_frames: queued,
      queued_bytes: queued_bytes,
      frames_in: frames_in,
      frames_out: frames_out,
      overloads: overloads,
      dropped: dropped,
      malformed: malformed,
      protocol_errors: protocol_errors,
      closed: closed?,
      child_status: child_status
    }
  end

  @doc """
  Absolute path of the native host executable inside this application.

  Resolved through the application so that a release finds its artifact without
  any reference to the source tree or the current working directory.
  """
  @spec host_executable() :: String.t()
  def host_executable do
    Application.app_dir(:live_cimgui, Path.join(["priv", "native", "live_cimgui_host"]))
  end
end
