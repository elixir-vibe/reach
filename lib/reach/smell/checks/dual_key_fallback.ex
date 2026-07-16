defmodule Reach.Smell.Checks.DualKeyFallback do
  @moduledoc "Detects atom/string fallback helpers that entrench loose map contracts."

  @behaviour Reach.Smell.Check

  alias Reach.Evidence.MapContract
  alias Reach.Smell.{Finding, Helpers}

  @impl true
  def kinds, do: [:dual_key_fallback, :false_collapsing_lookup]

  @impl true
  def run(project) do
    project
    |> MapContract.collect_fallbacks()
    |> Enum.filter(& &1.returned?)
    |> Enum.group_by(& &1.node.id)
    |> Enum.flat_map(fn {_node_id, fallbacks} ->
      Enum.map(fallbacks, &dual_key_finding/1) ++ false_collapse_findings(fallbacks)
    end)
  end

  defp dual_key_finding(fallback) do
    key = fallback.accesses |> List.first() |> Map.fetch!(:key_label)

    Finding.new(
      kind: :dual_key_fallback,
      message:
        "map key #{inspect(key)} is read through atom/string fallback representations; normalize the map once at its boundary",
      location: Helpers.location(fallback.node),
      evidence: evidence(fallback),
      confidence: :high
    )
  end

  defp false_collapse_findings(fallbacks) do
    case Enum.find(
           fallbacks,
           &(&1.operator == :or and &1.default? and &1.boolean_evidence != [])
         ) do
      nil ->
        []

      fallback ->
        [
          Finding.new(
            kind: :false_collapsing_lookup,
            message:
              "Map.get/2 results are chained with || before a default; an explicit false value is treated as missing",
            location: Helpers.location(fallback.node),
            evidence: Enum.flat_map(fallbacks, &evidence/1) |> Enum.uniq(),
            confidence: :high
          )
        ]
    end
  end

  defp evidence(fallback) do
    Enum.map(fallback.accesses, &Helpers.location(&1.node)) |> Enum.uniq()
  end
end
