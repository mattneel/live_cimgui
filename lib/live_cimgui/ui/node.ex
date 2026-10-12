defmodule LiveCimgui.UI.Node do
  @moduledoc """
  A typed native UI description node.

  Nodes are produced by the constructors in `LiveCimgui.UI` and are the only
  thing `render/1` may return. The vocabulary is deliberately small:

  | kind | children | interactive |
  |---|---|---|
  | `:text` | none | no |
  | `:button` | none | yes |
  | `:input` | none | yes |
  | `:row` | nodes | no |
  | `:column` | nodes | no |
  | `:keyed` | keyed children | no |
  | `:diagnostics` | none | no |

  Interactive nodes (`:button`, `:input`) carry an explicit stable `id` and an
  `incarnation`. Identity is the pair `{id, incarnation}`: the `id` must survive
  reorders, and the `incarnation` must change when an application logically
  deletes a widget and later creates a new one under the same id.

  Structural nodes (`:row`, `:column`, `:keyed`) have no identity of their own.
  A child's *path* is derived from its ancestors (`row/0/keyed-list/alpha`), so
  unkeyed children still get position-scoped identity while keyed children keep
  their identity across a reorder.

  `:diagnostics` renders host-owned live counters (frame progress, draft and
  acknowledged revisions, queue pressure) directly from native state. It is the
  only node whose content is not supplied by Elixir, which is what makes the
  window honest while an Elixir callback is stalled.
  """

  @type kind :: :text | :button | :input | :row | :column | :keyed | :diagnostics

  @type t :: %__MODULE__{
          kind: kind(),
          id: String.t() | nil,
          incarnation: pos_integer() | nil,
          text: String.t() | nil,
          label: String.t() | nil,
          event: String.t() | nil,
          value: String.t() | nil,
          key: String.t() | nil,
          children: [t() | keyed_child()]
        }

  @type keyed_child :: {String.t(), pos_integer(), t()}

  @enforce_keys [:kind]
  defstruct kind: nil,
            id: nil,
            incarnation: nil,
            text: nil,
            label: nil,
            event: nil,
            value: nil,
            key: nil,
            children: []
end
