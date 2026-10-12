defmodule LiveCimgui.HostSupervisor do
  @moduledoc """
  Supervisor for `LiveCimgui.HostManager` processes.

  One host manager owns one native window. The manager is a child process, never
  a linked helper of the caller: `LiveCimgui.Demo.start/1` starts its manager
  here, so a manager that exhausts its restart policy takes nothing else down and
  an IEx session that started a window keeps its own process free.

      {:ok, manager} = DynamicSupervisor.start_child(LiveCimgui.HostSupervisor, {LiveCimgui.HostManager, opts})

  This supervisor is part of the application supervision tree (see
  `LiveCimgui.Application`). It starts no window by itself: a window exists only
  while some process starts a manager.
  """

  use DynamicSupervisor

  @doc """
  Starts the supervisor.

  Options: `:name` (registered name, defaults to `#{inspect(__MODULE__)}`).
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl DynamicSupervisor
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
end
