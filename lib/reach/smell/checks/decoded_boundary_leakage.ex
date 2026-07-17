defmodule Reach.Smell.Checks.DecodedBoundaryLeakage do
  @moduledoc "Detects decoded external maps crossing storage or process boundaries unchanged."

  @behaviour Reach.Smell.Check

  alias Reach.Evidence
  alias Reach.Smell.Finding

  @min_literal_consumer_keys 2

  @impl true
  def kinds, do: [:decoded_boundary_leakage]

  @impl true
  def run(project) do
    project
    |> Evidence.external_data_boundaries()
    |> Enum.filter(&(length(&1.consumer_keys) >= @min_literal_consumer_keys))
    |> Enum.map(&finding/1)
  end

  defp finding(fact) do
    Finding.new(
      kind: :decoded_boundary_leakage,
      message:
        "decoded external data from #{fact.source} crosses #{fact.boundary} without explicit normalization",
      location: "#{fact.file}:#{fact.line}",
      evidence:
        "downstream literal keys=#{Enum.join(fact.consumer_keys, ",")}; normalize into a struct or validated contract before #{fact.boundary}; fix the boundary, not downstream consumers.",
      confidence: :high
    )
  end
end
