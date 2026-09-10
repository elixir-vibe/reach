defmodule Reach.Effects.Cache do
  @moduledoc false

  use GenServer

  @tables [:reach_classify_cache, :reach_dependency_effect_cache]

  # Reach also runs without application startup (for example, mix run --no-start).
  # Start an unlinked owner lazily so caches survive short-lived analysis workers.
  @spec ensure_started() :: :ok
  def ensure_started do
    if Enum.all?(@tables, &(:ets.whereis(&1) != :undefined)) do
      :ok
    else
      case GenServer.start(__MODULE__, nil, name: __MODULE__) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, pid}} -> GenServer.call(pid, :ready)
      end
    end
  end

  @impl true
  def init(nil) do
    Enum.each(@tables, &:ets.new(&1, [:set, :public, :named_table, read_concurrency: true]))
    {:ok, nil}
  end

  @impl true
  def handle_call(:ready, _from, state), do: {:reply, :ok, state}
end
