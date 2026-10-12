defmodule LiveCimgui.PhoenixAdapterTest do
  @moduledoc """
  Pins the Phoenix facilities live_cimgui actually relies on.

  These are the compatibility claims made in `LiveCimgui.PhoenixAdapter` and in
  `docs/ARCHITECTURE.md`: the view lifecycle is LiveView's *callback* shape over
  a `%Phoenix.LiveView.Socket{}`, driven by `LiveCimgui.ViewServer` — not a
  LiveView runtime. If a Phoenix upgrade changes any of these behaviours, this
  file fails and the adapter is the only file that needs changing.
  """

  use ExUnit.Case, async: true

  alias LiveCimgui.PhoenixAdapter
  alias Phoenix.Component
  alias Phoenix.LiveView.Socket

  defmodule MinimalView do
    use LiveCimgui.View

    def mount(_params, _session, socket), do: {:ok, assign(socket, :loaded, true)}
    def render(assigns), do: LiveCimgui.UI.text("loaded=#{assigns.loaded}")
    def handle_event(_name, _params, socket), do: {:noreply, socket}
  end

  describe "build_socket/1" do
    test "builds a Phoenix LiveView socket with the change-tracking key already present" do
      socket = PhoenixAdapter.build_socket()

      assert %Socket{} = socket
      assert socket.assigns.__changed__ == %{}
      assert socket.private == %{live_cimgui_view: nil, live_cimgui_generation: nil}
      assert socket.id == nil and socket.router == nil and socket.endpoint == nil
    end

    test "records the view module and generation in private data" do
      socket = PhoenixAdapter.build_socket(view: MinimalView, generation: 7)

      assert PhoenixAdapter.private(socket, :live_cimgui_view) == MinimalView
      assert PhoenixAdapter.private(socket, :live_cimgui_generation) == 7
    end
  end

  describe "assigns" do
    test "assign/3 is Phoenix.Component.assign and records the changed key" do
      socket = PhoenixAdapter.build_socket() |> PhoenixAdapter.assign(:rows, [1, 2, 3])

      assert socket.assigns.rows == [1, 2, 3]
      assert socket.assigns.__changed__.rows == true
    end

    test "assigning on a socket without __changed__ raises, which is why build_socket/1 seeds it" do
      bare = %Socket{assigns: %{}}

      assert_raise KeyError, fn -> Component.assign(bare, :something, 1) end
    end

    test "update/3 rewrites a key with a function" do
      socket =
        PhoenixAdapter.build_socket()
        |> PhoenixAdapter.assign(:count, 1)
        |> PhoenixAdapter.update(:count, &(&1 + 1))

      assert socket.assigns.count == 2
    end

    test "assign_many/2 accepts a map and a keyword list" do
      from_map = PhoenixAdapter.assign_many(PhoenixAdapter.build_socket(), %{a: 1, b: 2})
      from_kw = PhoenixAdapter.assign_many(PhoenixAdapter.build_socket(), a: 1, b: 2)

      assert {from_map.assigns.a, from_map.assigns.b} == {1, 2}
      assert {from_kw.assigns.a, from_kw.assigns.b} == {1, 2}
    end

    test "assigns/1 returns the assigns with change tracking reset for the next render" do
      socket = PhoenixAdapter.build_socket() |> PhoenixAdapter.assign(:rows, [1])

      assigns = PhoenixAdapter.assigns(socket)

      assert assigns.rows == [1]
      assert assigns.__changed__ == %{}
    end

    test "checkpoint/1 drops framework bookkeeping and keeps presentation state" do
      socket = PhoenixAdapter.build_socket() |> PhoenixAdapter.assign(:rows, [1])

      refute Map.has_key?(PhoenixAdapter.checkpoint(socket), :__changed__)
      assert PhoenixAdapter.checkpoint(socket).rows == [1]
    end

    test "replay_checkpoint/2 re-assigns presentation state on a fresh socket" do
      socket =
        PhoenixAdapter.replay_checkpoint(PhoenixAdapter.build_socket(), %{
          rows: [1, 2],
          __changed__: %{rows: true}
        })

      assert socket.assigns.rows == [1, 2]

      # Replayed assigns are assigned through Phoenix, so the next render sees
      # them as changed -- and the framework key is still present.
      assert is_map(socket.assigns.__changed__)
      assert socket.assigns.__changed__.rows == true
    end

    test "missing assigns raise KeyError rather than rendering as nil" do
      assigns = PhoenixAdapter.assigns(PhoenixAdapter.build_socket())

      assert_raise KeyError, fn -> Map.fetch!(assigns, :never_assigned) end
    end
  end

  describe "private data" do
    test "put_private/3 and private/2 round trip without touching assigns" do
      socket =
        PhoenixAdapter.build_socket()
        |> PhoenixAdapter.assign(:rows, [])
        |> PhoenixAdapter.put_private(:manager, self())

      assert PhoenixAdapter.private(socket, :manager) == self()
      assert PhoenixAdapter.assigns(socket).rows == []
    end
  end

  describe "the view contract" do
    test "use Livecimgui.View provides a default handle_info/2" do
      assert function_exported?(MinimalView, :handle_info, 2)
      assert function_exported?(MinimalView, :mount, 3)
      assert function_exported?(MinimalView, :render, 1)
      assert function_exported?(MinimalView, :handle_event, 3)
    end

    test "the default handle_info/2 is a no-op that keeps the socket" do
      socket = PhoenixAdapter.build_socket()

      assert MinimalView.handle_info(:anything, socket) == {:noreply, socket}
    end

    test "a view's mount/3 receives the socket built by the adapter" do
      socket = PhoenixAdapter.build_socket(view: MinimalView, generation: 3)

      assert {:ok, %Socket{} = mounted} = MinimalView.mount(%{"k" => "v"}, %{}, socket)
      assert mounted.assigns.loaded == true
    end

    test "render/1 receives the assigns map, exactly like a LiveView render" do
      socket = PhoenixAdapter.build_socket() |> PhoenixAdapter.assign(:loaded, false)

      assert %LiveCimgui.UI.Node{kind: :text, text: "loaded=false"} =
               MinimalView.render(PhoenixAdapter.assigns(socket))
    end
  end
end
