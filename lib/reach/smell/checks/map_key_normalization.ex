defmodule Reach.Smell.Checks.MapKeyNormalization do
  @moduledoc "Detects lossy map-key normalization and representation churn."

  @behaviour Reach.Smell.Check

  alias Reach.Evidence.MapContract
  alias Reach.Smell.{Finding, Helpers}

  @impl true
  def kinds, do: [:key_normalization_collision, :key_representation_churn]

  @impl true
  def run(project) do
    normalizations = MapContract.collect_key_normalizations(project)
    collision_findings(normalizations) ++ churn_findings(project, normalizations)
  end

  defp collision_findings(normalizations) do
    normalizations
    |> Enum.group_by(&{&1.map_node.id, &1.direction})
    |> Enum.map(fn {_identity, alternatives} ->
      normalization = Enum.min_by(alternatives, &normalization_sort_key/1)
      {source, target} = representations(normalization.direction)

      Finding.new(
        kind: :key_normalization_collision,
        message:
          "map key normalization converts #{source} keys to #{target} keys while preserving existing #{target} keys; equivalent keys can silently overwrite each other",
        location: Helpers.location(normalization.node),
        evidence:
          alternatives
          |> Enum.sort_by(&normalization_sort_key/1)
          |> Enum.map(&Helpers.location(&1.node))
          |> Enum.uniq(),
        confidence: :high
      )
    end)
  end

  defp normalization_sort_key(normalization) do
    {normalization.node.meta[:line] || 0, normalization.node.meta[:column] || 0,
     normalization.node.id}
  end

  defp churn_findings(project, normalizations) do
    project
    |> MapContract.collect_representation_churn(normalizations)
    |> Enum.map(fn churn ->
      {first_source, first_target} = representations(churn.first.direction)
      {_second_source, second_target} = representations(churn.second.direction)

      Finding.new(
        kind: :key_representation_churn,
        message:
          "map keys are converted from #{first_source} to #{first_target} and back to #{second_target} along one value-flow path; choose one internal representation",
        location: Helpers.location(churn.node),
        evidence: [Helpers.location(churn.first.node), Helpers.location(churn.second.node)],
        confidence: :high
      )
    end)
  end

  defp representations(:atom_to_string), do: {"atom", "string"}
  defp representations(:string_to_atom), do: {"string", "atom"}
end
