defmodule LiveCimgui.Protocol.Reader do
  @moduledoc false
  # Primitive readers for the wire format. Each returns `{:ok, value, rest}`.
  # Lengths are validated before a slice is taken, so a hostile or truncated
  # body produces a defined error instead of a huge allocation.

  @type result(value) :: {:ok, value, binary()} | {:error, term()}

  @spec u8(binary()) :: result(0..255)
  def u8(<<value::8, rest::binary>>), do: {:ok, value, rest}
  def u8(_body), do: {:error, {:truncated, :u8}}

  @spec u32(binary()) :: result(non_neg_integer())
  def u32(<<value::little-32, rest::binary>>), do: {:ok, value, rest}
  def u32(_body), do: {:error, {:truncated, :u32}}

  @spec u64(binary()) :: result(non_neg_integer())
  def u64(<<value::little-64, rest::binary>>), do: {:ok, value, rest}
  def u64(_body), do: {:error, {:truncated, :u64}}

  @spec f64(binary()) :: result(float())
  def f64(<<value::little-float-64, rest::binary>>), do: {:ok, value, rest}
  def f64(_body), do: {:error, {:truncated, :f64}}

  @doc "Reads a length-prefixed string, rejecting anything longer than `limit`."
  @spec string(binary(), pos_integer()) :: result(binary())
  def string(<<size::little-32, rest::binary>>, limit) when size <= limit do
    case rest do
      <<value::binary-size(^size), tail::binary>> -> {:ok, value, tail}
      _short -> {:error, {:truncated, {:string, size}}}
    end
  end

  def string(<<size::little-32, _rest::binary>>, limit),
    do: {:error, {:string_too_long, %{size: size, limit: limit}}}

  def string(_body, _limit), do: {:error, {:truncated, :string_length}}

  @doc "Asserts the body is fully consumed."
  @spec done(binary()) :: :ok | {:error, term()}
  def done(<<>>), do: :ok
  def done(leftover), do: {:error, {:trailing_bytes, byte_size(leftover)}}
end
