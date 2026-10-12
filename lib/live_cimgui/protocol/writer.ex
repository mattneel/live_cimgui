defmodule LiveCimgui.Protocol.Writer do
  @moduledoc false
  # Primitive writers for the wire format. Every function returns iodata; the
  # caller validates lengths so that no message is built from invalid input.

  @spec u8(0..255) :: binary()
  def u8(value), do: <<value::8>>

  @spec u32(non_neg_integer()) :: binary()
  def u32(value), do: <<value::little-32>>

  @spec u64(non_neg_integer()) :: binary()
  def u64(value), do: <<value::little-64>>

  @spec f64(number()) :: binary()
  def f64(value), do: <<value::little-float-64>>

  @spec bool(boolean()) :: binary()
  def bool(true), do: <<1::8>>
  def bool(false), do: <<0::8>>

  @spec string(binary()) :: iodata()
  def string(value), do: [<<byte_size(value)::little-32>>, value]

  @doc "Flattens iodata into a binary."
  @spec to_binary(iodata()) :: binary()
  def to_binary(iodata), do: IO.iodata_to_binary(iodata)
end
