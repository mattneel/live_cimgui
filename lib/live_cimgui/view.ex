defmodule LiveCimgui.View do
  @moduledoc """
  The view contract: `use LiveCimgui.View` in a module that renders a native
  window.

  ## Lifecycle

      mount(params, session, socket) :: {:ok, socket}
      render(assigns) :: LiveCimgui.UI.Node.t()
      handle_event(event_name, params, socket) :: {:noreply, socket}
      handle_info(message, socket) :: {:noreply, socket}

  `mount/3` runs once per view process incarnation, `render/1` runs after every
  mount, event, or message, and `handle_event/3` receives native interaction:

    * `{"button-id", %{"event" => "button-id", "incarnation" => 1}}` for clicks;
    * `{"editor-id", %{"value" => text, "draft_revision" => n, "incarnation" => 1}}`
      for text edits, where `value` is the complete UTF-8 draft from the native
      editor and `draft_revision` is the native revision it came from.

  `handle_info/2` receives everything else: application messages, subscription
  deliveries, and framework messages such as
  `{:live_cimgui, :drafts, drafts}` (surviving native drafts after the view
  restarted) and `{:live_cimgui, :host_restarted, map}`.

  ## What this is

  Callbacks and assigns are LiveView's (`Phoenix.LiveView.Socket`,
  `Phoenix.Component.assign/2,3`); the process driving them is
  `LiveCimgui.ViewServer`, not LiveView's runtime. See
  `LiveCimgui.PhoenixAdapter` for the exact compatibility level, and
  `docs/ARCHITECTURE.md` for the ownership boundaries between the view, the
  application service, and the native host.
  """

  alias LiveCimgui.PhoenixAdapter
  alias LiveCimgui.UI

  @type socket :: PhoenixAdapter.socket()

  @doc "Initializes presentation state. Called once per view process incarnation."
  @callback mount(params :: map(), session :: map(), socket :: socket()) :: {:ok, socket()}

  @doc "Returns the complete native description for the current assigns."
  @callback render(assigns :: map()) :: UI.Node.t()

  @doc "Handles one native interaction."
  @callback handle_event(name :: String.t(), params :: map(), socket :: socket()) ::
              {:noreply, socket()}

  @doc "Handles application and framework messages."
  @callback handle_info(message :: term(), socket :: socket()) :: {:noreply, socket()}

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour LiveCimgui.View

      import Phoenix.Component, only: [assign: 2, assign: 3, update: 3]

      @impl LiveCimgui.View
      def handle_info(_message, socket), do: {:noreply, socket}

      defoverridable handle_info: 2
    end
  end
end
