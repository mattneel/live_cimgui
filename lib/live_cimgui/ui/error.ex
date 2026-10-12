defmodule LiveCimgui.UI.Error do
  @moduledoc """
  Raised when a UI description is not a valid native render target.

  The message always names the offending kind, property, or identity and the
  path inside the description where it was found, so an authoring mistake is
  reported at the declaration site rather than as a native failure.
  """

  defexception [:message, :path, :reason]

  @type t :: %__MODULE__{message: String.t(), path: String.t() | nil, reason: term()}

  @doc false
  @spec exception(keyword()) :: t()
  def exception(fields) do
    path = Keyword.get(fields, :path)
    reason = Keyword.get(fields, :reason)
    %__MODULE__{message: message(reason, path), path: path, reason: reason}
  end

  defp message(reason, nil), do: reason |> to_string()
  defp message(reason, path), do: "#{reason} (at #{path})"
end
