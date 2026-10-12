defmodule LiveCimgui.ViewServer do
  @moduledoc """
  Drives one `LiveCimgui.View` module's callbacks.

  This is the adapter between the LiveView-shaped callbacks and the host
  manager. It is **not** a LiveView runtime: it is a plain `GenServer` that
  builds a `%Phoenix.LiveView.Socket{}` through `LiveCimgui.PhoenixAdapter`,
  calls `mount/3` / `render/1` / `handle_event/3` / `handle_info/2`, and hands
  each rendered description to `LiveCimgui.HostManager`.

  Responsibilities, and the boundary with the manager:

    * the view process owns presentation state and subscriptions, and may block
      for as long as its own callbacks take — the native window keeps rendering
      because the manager, the NIF, and the host are separate;
    * the manager owns the native resource, the UI revision, the view
      generation, and event routing.

  Restart behaviour: a view crash is isolated. The host manager keeps the native
  window, the supervisor starts a replacement `ViewServer`, and the replacement
  registers with the manager to receive a fresh view generation (see
  `LiveCimgui.HostManager.register_view/2`).
  """

  use GenServer, restart: :temporary

  require Logger

  alias LiveCimgui.HostManager
  alias LiveCimgui.PhoenixAdapter
  alias LiveCimgui.UI

  @type state :: %{
          manager: pid(),
          view: module(),
          generation: non_neg_integer(),
          socket: PhoenixAdapter.socket(),
          render_ref: reference() | nil
        }

  @doc """
  Starts a view process.

  Options: `:manager` (required pid), `:view` (required module), `:params`
  (map), `:session` (map).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @doc "Returns the presentation checkpoint of a running view (used by supervisors)."
  @spec checkpoint(pid()) :: map()
  def checkpoint(pid) when is_pid(pid), do: GenServer.call(pid, :checkpoint)

  @impl GenServer
  def init(opts) do
    manager = Keyword.fetch!(opts, :manager)
    view = Keyword.fetch!(opts, :view)

    {:ok, generation, checkpoint} = HostManager.register_view(manager, self())

    socket =
      PhoenixAdapter.build_socket(view: view, generation: generation)
      |> PhoenixAdapter.put_private(:manager, manager)
      |> PhoenixAdapter.replay_checkpoint(checkpoint)

    {:ok, socket} =
      view.mount(Keyword.get(opts, :params, %{}), Keyword.get(opts, :session, %{}), socket)

    state = %{
      manager: manager,
      view: view,
      generation: generation,
      socket: socket,
      render_ref: nil
    }

    Logger.debug("live_cimgui view #{inspect(view)} started in generation #{generation}")
    {:ok, state, {:continue, :render}}
  end

  @impl GenServer
  def handle_continue(:render, state), do: {:noreply, commit(state)}

  @impl GenServer
  def handle_call(:checkpoint, _from, state),
    do: {:reply, PhoenixAdapter.checkpoint(state.socket), state}

  @impl GenServer
  def handle_info({:live_cimgui_event, render_ref, event}, state) do
    {name, params} = normalize_event(event)

    case dispatch_event(state, name, params) do
      {:ok, state} ->
        {:noreply, commit_with_ref(%{state | render_ref: render_ref})}

      {:error, reason, crash} ->
        # A failing callback is a view bug: log it and let the supervisor
        # replace this process. The native window stays alive.
        Logger.error("live_cimgui view event #{inspect(name)} failed: #{inspect(reason)}")
        {:stop, crash, state}
    end
  end

  def handle_info(message, state) do
    case state.view.handle_info(message, state.socket) do
      {:noreply, socket} -> {:noreply, commit_with_ref(%{state | socket: socket})}
      other -> {:stop, {:bad_return, other}, state}
    end
  rescue
    error ->
      Logger.error("live_cimgui view handle_info/2 raised: #{Exception.message(error)}")
      reraise error, __STACKTRACE__
  end

  @impl GenServer
  def terminate(_reason, _state) do
    :ok
  end

  ## Internals

  defp normalize_event({:button_click, id, incarnation, event}) do
    {event, %{"id" => id, "incarnation" => incarnation, "event" => event}}
  end

  defp normalize_event({:input_submit, id, incarnation, draft_revision, text}) do
    {id,
     %{
       "id" => id,
       "incarnation" => incarnation,
       "value" => text,
       "draft_revision" => draft_revision,
       "action" => "submit"
     }}
  end

  defp normalize_event({:input_edit, id, incarnation, draft_revision, text}) do
    {id,
     %{
       "id" => id,
       "incarnation" => incarnation,
       "value" => text,
       "draft_revision" => draft_revision,
       "action" => "edit"
     }}
  end

  defp normalize_event(:window_close), do: {"window_close", %{"action" => "close"}}

  defp dispatch_event(state, name, params) do
    {:noreply, socket} = state.view.handle_event(name, params, state.socket)
    state = %{state | socket: socket}

    # Text drafts are acknowledged after the handler accepted them, before the
    # next description is published, so the host never has to guess whether a
    # draft was accepted.
    with %{"draft_revision" => revision, "id" => id, "incarnation" => incarnation} <- params do
      :ok = HostManager.acknowledge(state.manager, state.generation, id, incarnation, revision)
    end

    {:ok, state}
  rescue
    error -> {:error, error, {:view_event_failed, name}}
  end

  defp commit(state), do: commit_with_ref(state)

  defp commit_with_ref(state) do
    node =
      state.socket
      |> PhoenixAdapter.assigns()
      |> state.view.render()
      |> UI.validate!()

    :ok =
      HostManager.render(
        state.manager,
        %{pid: self(), generation: state.generation, render_ref: state.render_ref},
        PhoenixAdapter.checkpoint(state.socket),
        node
      )

    %{
      state
      | socket: %{state.socket | assigns: PhoenixAdapter.assigns(state.socket)},
        render_ref: nil
    }
  end
end
