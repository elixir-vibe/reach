defmodule Reach.Evidence.Impact do
  @moduledoc "Reusable call-graph impact evidence for target-local analyses and checks."

  @spec callers(Reach.Project.t(), {module(), atom(), non_neg_integer()}, non_neg_integer()) :: [
          {module() | nil, atom(), non_neg_integer()}
        ]
  def callers(project, target, depth) do
    call_graph = project.call_graph

    if Graph.has_vertex?(call_graph, target) do
      collect_callers(call_graph, [target], depth, MapSet.new([target]), [])
    else
      []
    end
  end

  defp collect_callers(_graph, [], _depth, _visited, callers), do: Enum.reverse(callers)
  defp collect_callers(_graph, _frontier, 0, _visited, callers), do: Enum.reverse(callers)

  defp collect_callers(graph, frontier, depth, visited, callers) do
    {new_callers, visited} = next_callers(graph, frontier, visited)
    callers = Enum.reverse(new_callers, callers)

    if depth > 1 do
      collect_callers(graph, new_callers, depth - 1, visited, callers)
    else
      Enum.reverse(callers)
    end
  end

  defp next_callers(graph, frontier, visited) do
    Enum.reduce(frontier, {[], visited}, fn function, {callers, visited} ->
      found =
        graph
        |> Graph.in_neighbors(function)
        |> Enum.filter(&match?({_, _, _}, &1))
        |> Enum.reject(&MapSet.member?(visited, &1))

      {Enum.reverse(found, callers), Enum.reduce(found, visited, &MapSet.put(&2, &1))}
    end)
  end
end
