defmodule Reach.Smell.Checks.FixedShapeMap do
  @moduledoc "Detects repeated constructed map literals that should be structs."

  @behaviour Reach.Smell.Check

  alias Reach.IR.Node
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
    |> constructed_maps()
    |> Enum.reject(&supervisor_child_spec?(&1, function))
    |> Enum.flat_map(&map_shape(&1, config))
  end

  # Conditions and timeouts, unlike case/fn patterns, are evaluated expressions.
  defp constructed_maps(%{type: :clause, meta: %{kind: kind}, children: children})
       when kind in [:cond_clause, :timeout_clause, :true_branch, :false_branch] do
    Enum.flat_map(children, &constructed_maps/1)
  end

  defp constructed_maps(%{type: :clause, meta: %{kind: :with_clause}, children: children}) do
    children |> List.last() |> constructed_maps()
  end

  # Clause heads describe accepted data; only the body and guards are expressions.
  defp constructed_maps(%{type: type, children: children})
       when type in [:clause, :rescue, :catch_clause] do
    expressions =
      case children do
        [] -> []
        _ -> Enum.filter(Enum.drop(children, -1), &(&1.type == :guard)) ++ [List.last(children)]
      end

    Enum.flat_map(expressions, &constructed_maps/1)
  end

  defp constructed_maps(%{type: type, children: [_pattern, expression]})
       when type in [:match, :generator] do
    constructed_maps(expression)
  end

  # Attributes (including specs/types) and quoted syntax are not runtime records.
  defp constructed_maps(%{type: :call, meta: %{function: function}})
       when function in [:@, :quote],
       do: []

  defp constructed_maps(%{type: :map, children: children} = node) do
    nested = Enum.flat_map(children, &constructed_maps/1)

    if node.source_span && node.meta[:kind] != :update &&
         Enum.all?(children, &(&1.type == :map_field and &1.meta[:kind] != :update)) do
      [node | nested]
    else
      nested
    end
  end

  defp constructed_maps(%Node{children: children}),
    do: Enum.flat_map(children, &constructed_maps/1)

  defp constructed_maps(nil), do: []

  # child_spec/1 already returns the Supervisor contract, not application domain data.
  # Do not exempt the same literal in other functions, or extra application fields.
  defp supervisor_child_spec?(map, %{meta: %{name: :child_spec, arity: 1}} = function) do
    fields =
      Map.new(map.children, fn field -> {List.first(field.children).meta[:value], field} end)

    allowed_keys = [:id, :start, :restart, :shutdown, :type, :modules]

    map.id in returned_map_ids(function) and Map.has_key?(fields, :id) and
      Enum.all?(Map.keys(fields), &(&1 in allowed_keys)) and
      start_mfa?(fields[:start])
  end

  defp supervisor_child_spec?(_map, _function), do: false

  defp start_mfa?(%{
         children: [
           _,
           %{
             type: :tuple,
             children: [_, %{type: :literal, meta: %{value: function}}, %{type: :list}]
           }
         ]
       })
       when is_atom(function),
       do: true

  defp start_mfa?(_field), do: false

  defp returned_map_ids(%{type: :map, id: id}), do: [id]

  defp returned_map_ids(%{type: :function_def, children: clauses}),
    do: Enum.flat_map(clauses, &returned_map_ids/1)

  defp returned_map_ids(%{type: type, children: children}) when type in [:block, :clause],
    do: returned_map_ids(List.last(children))

  defp returned_map_ids(%{type: :case, children: children}),
    do: children |> Enum.filter(&(&1.type == :clause)) |> Enum.flat_map(&returned_map_ids/1)

  defp returned_map_ids(_node), do: []

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
