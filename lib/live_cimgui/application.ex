defmodule LiveCimgui.Application do
  @moduledoc """
  The application supervision tree.

      LiveCimgui.Supervisor
      ├── LiveCimgui.HostSupervisor   (DynamicSupervisor for host managers)
      └── LiveCimgui.Demo.State       (the demo application service)

  The tree deliberately starts no window: windows are started on demand —
  `LiveCimgui.Demo.start/1`, or `LiveCimgui.HostManager.start_link/1` under
  `LiveCimgui.HostSupervisor` — so `mix compile`, `mix test`, and a plain
  `iex -S mix` never open a native host they do not need.

  `LiveCimgui.Demo.State` is supervised here because it is the durable
  application state of the demo: killing a view process or a native host never
  touches it, and the window comes back reading the state it left behind.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      LiveCimgui.HostSupervisor,
      LiveCimgui.Demo.State
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: LiveCimgui.Supervisor)
  end
end
