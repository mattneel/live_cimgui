defmodule LiveCimgui.Protocol do
  @moduledoc """
  Framed, versioned messages between Elixir and the native host.

  See `docs/PROTOCOL.md` for the specification, revision ownership, and
  recovery rules. A frame is:

      <<size::unsigned-little-32, version::8, type::8, body::binary-size(size)>>

  `size` counts only `body` bytes and is validated before the body is touched,
  so a truncated, oversized, or unknown-version frame is rejected without
  partially mutating native state.

  Messages from Elixir to the host use type codes `1..31`; messages from the
  host to Elixir use `32..63`. Test-only and fault-injection messages live in
  the `16..31` range so they can never be confused with application commands.

  Encoding and decoding of bodies live in `LiveCimgui.Protocol.Codec`, which is
  the reference implementation the Zig host mirrors.
  """

  alias LiveCimgui.Protocol.Codec

  @protocol_version 1
  @max_frame_bytes 1_048_576
  @max_id_bytes 256

  @typedoc "A decoded protocol message."
  @type message :: tuple()

  @doc "Protocol version implemented by this module."
  @spec version() :: pos_integer()
  def version, do: @protocol_version

  @doc "Maximum accepted frame size in bytes."
  @spec max_frame_bytes() :: pos_integer()
  def max_frame_bytes, do: @max_frame_bytes

  @doc "Maximum size in bytes of one text or identity string."
  @spec max_text_bytes() :: pos_integer()
  def max_text_bytes, do: Codec.text_limit()

  @doc "Tree and message limits enforced before crossing the native boundary."
  @spec limits() :: map()
  def limits do
    Map.put(Codec.limits(), :frame_bytes, @max_frame_bytes)
  end

  @doc "Type code for a message name, or nil when unknown."
  @spec type_code(atom()) :: non_neg_integer() | nil
  def type_code(name), do: Codec.type_code(name)

  @doc "Message name for a type code, or nil when unknown."
  @spec type_name(non_neg_integer()) :: atom() | nil
  def type_name(code), do: Codec.type_name(code)

  @doc "Maximum size in bytes of one widget identity, key, or session id."
  @spec max_id_bytes() :: pos_integer()
  def max_id_bytes, do: @max_id_bytes

  @doc """
  Encodes a message into a complete frame.

  Every length is validated here, before anything reaches the native bridge, so
  a rejected message cannot partially mutate native state.
  """
  @spec encode(message()) :: {:ok, binary()} | {:error, term()}
  def encode(message) do
    with {:ok, type, body} <- Codec.encode(message) do
      frame_size(type, body)
    end
  end

  @doc "Encodes a message, raising `ArgumentError` on invalid input."
  @spec encode!(message()) :: binary()
  def encode!(message) do
    case encode(message) do
      {:ok, frame} -> frame
      {:error, reason} -> raise ArgumentError, "cannot encode message: #{inspect(reason)}"
    end
  end

  defp frame_size(_type, body) when byte_size(body) > @max_frame_bytes,
    do: {:error, {:frame_too_large, %{size: byte_size(body), limit: @max_frame_bytes}}}

  defp frame_size(type, body) do
    {:ok, <<byte_size(body)::little-32, @protocol_version::8, type::8, body::binary>>}
  end

  @doc """
  Decodes one complete frame.

  Returns `{:ok, message}`, `{:more, needed}` when `binary` is only a prefix of
  a frame, or `{:error, reason}` when the frame violates the protocol.
  """
  @spec decode(binary()) :: {:ok, message()} | {:more, pos_integer()} | {:error, term()}
  def decode(<<size::little-32, version::8, type::8, rest::binary>>)
      when byte_size(rest) >= size do
    <<body::binary-size(^size), _tail::binary>> = rest

    with :ok <- check_version(version) do
      Codec.decode(type, body)
    end
  end

  def decode(<<size::little-32, _version::8, _type::8, _rest::binary>>) do
    if size > @max_frame_bytes do
      {:error, {:frame_too_large, %{size: size, limit: @max_frame_bytes}}}
    else
      {:more, size}
    end
  end

  def decode(binary) when byte_size(binary) < 6, do: {:more, 6 - byte_size(binary)}

  @doc "Decodes a frame, raising `ArgumentError` when it is not complete or invalid."
  @spec decode!(binary()) :: message()
  def decode!(frame) do
    case decode(frame) do
      {:ok, message} -> message
      other -> raise ArgumentError, "cannot decode frame: #{inspect(other)}"
    end
  end

  @doc """
  Classifies a message tuple as an application event or a framework message.

  Application events come from user interaction and are delivered to
  `handle_event/3`; everything else is a framework message for `handle_info/2`.
  """
  @spec classify(message()) :: :event | :framework
  def classify({:event, _generation, _revision, _payload}), do: :event
  def classify(_message), do: :framework

  defp check_version(@protocol_version), do: :ok
  defp check_version(other), do: {:error, {:unsupported_version, other}}
end
