defmodule Reach.Smell.CorpusSnapshotTest do
  use ExUnit.Case, async: false

  alias Reach.Test.SmellCorpus

  @max_concurrency 2

  @tag timeout: 240_000
  test "pinned Hex packages match their accepted smell snapshots" do
    SmellCorpus.packages()
    |> Task.async_stream(&scan_package/1,
      max_concurrency: @max_concurrency,
      ordered: false,
      timeout: 180_000
    )
    |> Enum.each(fn
      {:ok, {package, identities}} ->
        if System.get_env("UPDATE_SMELL_CORPUS_SNAPSHOTS") == "1" do
          SmellCorpus.write_snapshot(package, identities)
        end

        assert SmellCorpus.snapshot(package) == identities

      {:exit, reason} ->
        flunk("smell corpus scan failed: #{inspect(reason)}")
    end)
  end

  defp scan_package(package), do: {package, SmellCorpus.identities(package)}
end
