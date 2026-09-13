defmodule Reach.Effects.CacheTest do
  use ExUnit.Case, async: false

  alias Reach.Effects.Cache

  @tables [:reach_classify_cache, :reach_dependency_effect_cache]
  @concurrent_workers 16

  setup do
    if pid = Process.whereis(Cache), do: GenServer.stop(pid)
    :ok
  end

  test "caches outlive the analysis worker that initializes them" do
    worker =
      Task.async(fn ->
        :ok = Reach.Effects.ensure_cache()

        for table <- @tables do
          :ets.insert(table, {:worker_result, :pure})
          {table, :ets.info(table, :owner)}
        end
      end)

    for {table, owner} <- Task.await(worker) do
      refute owner == worker.pid
      assert Process.alive?(owner)
      assert :ets.lookup(table, :worker_result) == [{:worker_result, :pure}]
    end
  end

  test "concurrent first callers share an initialized cache owner" do
    results =
      1..@concurrent_workers
      |> Task.async_stream(
        fn index ->
          :ok = Cache.ensure_started()
          :ets.insert(:reach_dependency_effect_cache, {index, :pure})
          :ets.info(:reach_dependency_effect_cache, :owner)
        end,
        max_concurrency: @concurrent_workers
      )
      |> Enum.map(fn {:ok, owner} -> owner end)

    assert [owner] = Enum.uniq(results)
    assert Process.alive?(owner)
    assert :ets.info(:reach_dependency_effect_cache, :size) == @concurrent_workers
  end
end
