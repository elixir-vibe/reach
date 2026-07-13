defmodule Reach.Smell.Checks.FixedShapeMap do
  @moduledoc "Detects repeated map literals that should be structs."

  @behaviour Reach.Smell.Check

  alias Reach.IR
  alias Reach.Smell.Finding
  alias Reach.Smell.Helpers

  @ignored_keys MapSet.new([:__struct__])

  @impl true
  def run(project), do: run(project, %{})

  def run(project, config) do
    config = fixed_shape_config(config)

    for({_, node} <- project.nodes, node.type == :function_def, do: node)
    |> Enum.flat_map(&maps_in_function(&1, config))
    |> Enum.group_by(& &1.keys)
    |> Enum.flat_map(&fixed_shape_finding(&1, config))
  end

  defp fixed_shape_config(%{smells: smells}), do: fixed_shape_config(smells)
  defp fixed_shape_config(%{fixed_shape_map: config}), do: fixed_shape_config(config)

  defp fixed_shape_config(config) do
    %{
      min_keys: Map.get(config, :min_keys, 3),
      min_occurrences: Map.get(config, :min_occurrences, 3),
      evidence_limit: Map.get(config, :evidence_limit, 10)
    }
  end

  defp maps_in_function(function, config) do
    function
    |> IR.all_nodes()
    |> Enum.filter(&(&1.type == :map and not is_nil(&1.source_span) and not map_pattern?(&1)))
    |> Enum.flat_map(&map_shape(&1, config))
  end

  defp map_shape(node, config) do
    keys =
      node.children
      |> Enum.flat_map(&field_key/1)
      |> Enum.reject(&MapSet.member?(@ignored_keys, &1))
      |> Enum.sort()

    if length(keys) >= config.min_keys do
      [%{keys: keys, location: Helpers.location(node)}]
    else
      []
    end
  end

  defp field_key(%{type: :map_field, children: [%{type: :literal, meta: %{value: key}} | _]})
       when is_atom(key) do
    [key]
  end

  defp field_key(_field), do: []

  defp map_pattern?(node) do
    node
    |> IR.all_nodes()
    |> Enum.any?(&(&1.meta[:binding_role] == :definition))
  end

  defp fixed_shape_finding({keys, occurrences}, config) do
    occurrence_count = length(occurrences)

    if occurrence_count >= config.min_occurrences do
      locations = occurrences |> Enum.map(& &1.location) |> Enum.uniq()

      [
        Finding.new(
          kind: :fixed_shape_map,
          message:
            "map shape #{inspect(keys)} appears #{occurrence_count} times; consider a struct or explicit contract if it is domain data",
          location: List.first(locations),
          evidence: Enum.take(locations, config.evidence_limit),
          keys: Enum.map(keys, &to_string/1),
          occurrences: occurrence_count
        )
      ]
    else
      []
    end
  end
end
