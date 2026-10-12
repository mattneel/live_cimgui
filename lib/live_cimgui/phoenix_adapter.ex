defmodule LiveCimgui.PhoenixAdapter do
  @moduledoc """
  The single place where live_cimgui touches Phoenix.

  ## Phoenix compatibility level (exact)

  live_cimgui is **callback-compatible with the LiveView view lifecycle, not a
  LiveView runtime**. Concretely, it uses two Phoenix facilities:

    * `Phoenix.LiveView.Socket` as the container handed to `mount/3`,
      `handle_event/3`, and `handle_info/2`, and
    * `Phoenix.Component.assign/2,3` and `Phoenix.Component.update/3` for
      assign management (which delegate to `Phoenix.LiveView.Utils`).

  It implements: `mount/3`, `render/1`, `handle_event/3`, `handle_info/2`,
  assigns with change tracking maintained through `assigns.__changed__`.

  It does **not** implement, and does not claim: a LiveView process or
  transport, `handle_params/3`, components or slots, HEEx or HTML rendering,
  `push_event`/`push_patch`/flash, connected/static distinction, or LiveView's
  `__changed__`-driven diff engine (the native target is diffed structurally by
  replacing whole validated descriptions). Arbitrary HTML LiveViews do not run
  unchanged, and calling this a renamed GenServer would be wrong in the other
  direction too: the callbacks really are the LiveView view callbacks, driven by
  `LiveCimgui.ViewServer` (see its docs for the exact adapter contract).

  Every function here exists so that a Phoenix upgrade has exactly one file to
  change; `LiveCimgui.PhoenixAdapterTest` pins the behaviours this project
  relies on.
  """

  alias Phoenix.Component
  alias Phoenix.LiveView.Socket

  @typedoc """
  A hand-built socket, which is what this adapter produces.

  It carries assigns and private data, and it is deliberately *not* a mounted
  LiveView socket: there is no router, endpoint, or view module behind it, and no
  transport. Saying that in the type keeps the honest boundary visible to the
  compiler and to Dialyzer instead of pretending this is `Socket.t()`.
  """
  @type socket :: %Socket{
          id: nil,
          endpoint: nil,
          view: nil,
          router: nil,
          assigns: map(),
          private: map()
        }

  @doc """
  Builds the socket handed to `mount/3`.

  `__changed__` is present from the start because `Phoenix.Component.assign/2,3`
  requires it on the target of an assign.
  """
  @spec build_socket(keyword()) :: socket()
  def build_socket(opts \\ []) do
    %Socket{
      assigns: %{__changed__: %{}},
      private: %{
        live_cimgui_view: Keyword.get(opts, :view),
        live_cimgui_generation: Keyword.get(opts, :generation)
      }
    }
  end

  @doc "Assigns one key, delegating change tracking to Phoenix."
  @spec assign(socket(), atom(), term()) :: socket()
  def assign(socket, key, value), do: Component.assign(socket, key, value)

  @doc "Updates one key with a function, delegating to Phoenix."
  @spec update(socket(), atom(), (term() -> term())) :: socket()
  def update(socket, key, fun), do: Component.update(socket, key, fun)

  @doc "Assigns a map of keys."
  @spec assign_many(socket(), map() | keyword()) :: socket()
  def assign_many(socket, assigns) when is_map(assigns),
    do: Enum.reduce(Map.to_list(assigns), socket, &assign(&2, elem(&1, 0), elem(&1, 1)))

  def assign_many(socket, assigns) when is_list(assigns),
    do: Enum.reduce(assigns, socket, &assign(&2, elem(&1, 0), elem(&1, 1)))

  @doc """
  Assigns every key of `checkpoint` and returns the socket.

  Used when a view restarts: presentation state that the framework checkpointed
  is replayed before the first render.
  """
  @spec replay_checkpoint(socket(), map()) :: socket()
  def replay_checkpoint(socket, checkpoint) when is_map(checkpoint) do
    checkpoint
    |> Map.drop([:__changed__, :__live_cimgui__])
    |> Enum.reduce(socket, fn {key, value}, acc -> assign(acc, key, value) end)
  end

  @doc "The raw assigns map, with change tracking reset for the next render."
  @spec assigns(socket()) :: map()
  def assigns(socket), do: Map.put(socket.assigns, :__changed__, %{})

  @doc """
  Framework-visible presentation state: assigns minus framework bookkeeping.

  This is what a supervisor replays into a replacement view process.
  """
  @spec checkpoint(socket()) :: map()
  def checkpoint(socket), do: Map.delete(socket.assigns, :__changed__)

  @doc "Private data live_cimgui stores on the socket."
  @spec private(socket(), atom()) :: term()
  def private(socket, key), do: Map.get(socket.private, key)

  @doc "Puts private data on the socket."
  @spec put_private(socket(), atom(), term()) :: socket()
  def put_private(socket, key, value),
    do: %{socket | private: Map.put(socket.private, key, value)}
end
