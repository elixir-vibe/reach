defmodule Reach.Test.ProgramFacts.Normalize do
  @moduledoc false

  def call_edges(%Graph.Edge{} = edge), do: call_edge(edge)

  def call_edges(edges) when is_list(edges) do
    edges
    |> Enum.map(&call_edge/1)
    |> MapSet.new()
  end

  def modules(modules) when is_map(modules), do: modules |> Map.keys() |> MapSet.new()
  def modules(modules) when is_list(modules), do: MapSet.new(modules)

  defp call_edge(%Graph.Edge{v1: source, v2: target}), do: normalize_edge({source, target})
  defp call_edge({source, target}), do: normalize_edge({source, target})

  defp normalize_edge(
         {{source_module, source_function, source_arity},
          {target_module, target_function, target_arity}}
       ) do
    {{source_module, source_function, source_arity},
     {target_module, target_function, target_arity}}
  end
end
