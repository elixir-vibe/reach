defmodule Reach.Inspect.Impact do
  @moduledoc """
  Builds impact summaries for a target function.
  """

  alias Reach.Evidence.Impact, as: ImpactEvidence
  alias Reach.IR
  alias Reach.IR.Helpers, as: IRHelpers

  @default_return_dependent_limit 20
  @default_dependency_node_limit 20

  def analyze(project, target, depth) do
    direct = find_callers(project, target, 1)
    transitive = find_callers(project, target, depth)
    indirect = Enum.reject(transitive, &(&1.id in Enum.map(direct, fn d -> d.id end)))

    return_deps = find_return_dependents(project, target)
    shared = find_shared_data(project, target)

    %{
      target: target,
      direct_callers: direct,
      transitive_callers: indirect,
      return_dependents: return_deps,
      shared_data: shared
    }
  end

  defp find_callers(project, target, depth) do
    project
    |> ImpactEvidence.callers(target, depth)
    |> Enum.map(&%{id: &1})
  end

  defp find_return_dependents(project, target) do
    graph = project.graph
    nodes = project.nodes
    target_key = tuple_with_nil(target)
    callers = find_callers(project, target, 1)

    callers
    |> Enum.flat_map(fn %{id: caller_id} ->
      caller_node = find_function(project, caller_id)
      if caller_node, do: return_deps_for_caller(caller_node, target_key, graph, nodes), else: []
    end)
    |> Enum.uniq_by(& &1.location)
    |> Enum.take(@default_return_dependent_limit)
  end

  defp return_deps_for_caller(caller_node, target_key, graph, nodes) do
    caller_id = {caller_node.meta[:module], caller_node.meta[:name], caller_node.meta[:arity]}

    call_sites =
      caller_node
      |> IR.all_nodes()
      |> Enum.filter(fn n ->
        n.type == :call and
          {n.meta[:module], n.meta[:function], n.meta[:arity] || 0} == target_key
      end)

    Enum.flat_map(call_sites, fn call_site ->
      deps_from_call_site(call_site, caller_id, graph, nodes)
    end)
  end

  defp deps_from_call_site(call_site, caller_id, graph, nodes) do
    if Graph.has_vertex?(graph, call_site.id) do
      graph
      |> Graph.reachable([call_site.id])
      |> Enum.take(@default_dependency_node_limit)
      |> Enum.map(&Map.get(nodes, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn dep_node ->
        %{
          in_function: caller_id,
          node_type: dep_node.type,
          location: IRHelpers.location(dep_node)
        }
      end)
    else
      []
    end
  end

  defp tuple_with_nil({_mod, fun, arity}), do: {nil, fun, arity}

  defp find_shared_data(project, target) do
    cg = project.call_graph

    if Graph.has_vertex?(cg, target) do
      project
      |> find_callers(target, 2)
      |> Enum.flat_map(&shared_data_for_caller(&1.id, cg, target))
      |> Enum.uniq()
      |> Enum.map(&IRHelpers.func_id_to_string/1)
    else
      []
    end
  end

  defp shared_data_for_caller(caller_id, cg, target) do
    cg
    |> Graph.out_neighbors(caller_id)
    |> Enum.filter(&(&1 == target))
    |> Enum.map(fn _ -> caller_id end)
  end

  defp find_function(project, target) do
    Enum.find_value(project.nodes, fn {_id, node} ->
      if node.type == :function_def and
           {node.meta[:module], node.meta[:name], node.meta[:arity]} == target,
         do: node
    end)
  end
end
