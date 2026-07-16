defmodule Reach.Trace.Flow do
  @moduledoc "Taint and variable flow tracing through data dependence edges."

  alias Reach.IR
  alias Reach.Project.Query
  alias Reach.Trace.Flow.{Path, Result}
  alias Reach.Trace.Pattern

  @max_intermediate_nodes 10

  def analyze_taint(project, from_pattern, to_pattern, max_paths) do
    sources = find_nodes(project, Pattern.compile(from_pattern, project.plugins))
    sinks = find_nodes(project, Pattern.compile(to_pattern, project.plugins))

    paths = find_taint_paths(project, sources, sinks, max_paths)

    Result.new(type: :taint, from: from_pattern, to: to_pattern, paths: paths)
  end

  @doc "Analyzes all source-to-sink routes in a named trace preset."
  def analyze_preset(project, pattern, max_paths) do
    case Pattern.preset(pattern, project.plugins) do
      {:ok, preset} ->
        paths =
          preset.routes
          |> Enum.flat_map(&preset_route_paths(project, &1, max_paths))
          |> Enum.uniq_by(&{&1.source.id, &1.sink.id})
          |> Enum.sort_by(&path_location_key/1)
          |> take_paths(max_paths)

        {:ok, Result.new(type: :taint, from: preset.from, to: preset.to, paths: paths)}

      :error ->
        {:error, :unknown_preset}
    end
  end

  def analyze_variable(project, var_name, scope) do
    scope_nodes = resolve_scope_nodes(project, scope)

    definitions =
      scope_nodes
      |> Enum.filter(fn node ->
        node.type == :var and node.meta[:binding_role] == :definition and
          to_string(node.meta[:name]) == var_name
      end)
      |> Enum.sort_by(&location_key/1)

    uses =
      scope_nodes
      |> Enum.filter(fn node ->
        node.type == :var and node.meta[:binding_role] != :definition and
          to_string(node.meta[:name]) == var_name
      end)
      |> Enum.sort_by(&location_key/1)

    Result.new(type: :variable, variable: var_name, definitions: definitions, uses: uses)
  end

  defp resolve_scope_nodes(project, nil), do: Map.values(project.nodes)

  defp resolve_scope_nodes(project, func_name) do
    nodes = Map.values(project.nodes)

    case Query.resolve_function(project, func_name) do
      nil ->
        nodes

      {mod, fun, arity} ->
        func_node =
          Enum.find(nodes, fn node ->
            node.type == :function_def and
              {node.meta[:module], node.meta[:name], node.meta[:arity]} == {mod, fun, arity}
          end)

        if func_node, do: IR.all_nodes(func_node), else: nodes
    end
  end

  defp find_nodes(project, filter) do
    for {_id, node} <- project.nodes, filter.(node), do: node
  end

  defp preset_route_paths(project, route, max_paths) do
    sources = find_nodes(project, route.source)
    sinks = find_nodes(project, route.sink)
    find_taint_paths(project, sources, sinks, max_paths)
  end

  defp take_paths(paths, :all), do: paths
  defp take_paths(paths, max_paths), do: Enum.take(paths, max_paths)

  defp path_location_key(path), do: {location_key(path.source), location_key(path.sink)}

  defp find_taint_paths(project, sources, sinks, max_paths) do
    graph = project.graph
    sink_by_id = Map.new(sinks, &{&1.id, &1})
    sink_ids = MapSet.new(Map.keys(sink_by_id))

    stream =
      sources
      |> Stream.flat_map(fn source -> reachable_sinks(graph, source, sink_ids, sink_by_id) end)
      |> Stream.map(fn {source, sink} -> build_path(project, source, sink) end)

    if max_paths == :all, do: Enum.to_list(stream), else: Enum.take(stream, max_paths)
  end

  defp reachable_sinks(graph, source, sink_ids, sink_by_id) do
    if Graph.has_vertex?(graph, source.id) do
      graph
      |> Graph.reachable([source.id])
      |> MapSet.new()
      |> MapSet.intersection(sink_ids)
      |> Enum.map(&{source, Map.fetch!(sink_by_id, &1)})
    else
      []
    end
  end

  defp build_path(project, source, sink) do
    graph = project.graph

    if Graph.has_vertex?(graph, source.id) and Graph.has_vertex?(graph, sink.id) do
      fwd = Graph.reachable(graph, [source.id]) |> MapSet.new()
      bwd = Graph.reaching(graph, [sink.id]) |> MapSet.new()
      path_ids = MapSet.intersection(fwd, bwd) |> MapSet.to_list()

      path_nodes =
        path_ids
        |> Enum.map(fn id -> Map.get(project.nodes, id) end)
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(& &1.source_span)
        |> Enum.sort_by(fn node -> {node.source_span[:file], node.source_span[:start_line]} end)
        |> Enum.uniq_by(fn node -> {node.source_span[:file], node.source_span[:start_line]} end)
        |> Enum.take(@max_intermediate_nodes)

      Path.new(source: source, sink: sink, intermediate: path_nodes)
    else
      Path.new(source: source, sink: sink, intermediate: [])
    end
  end

  defp location_key(node) do
    span = node.source_span || %{}
    {span[:file] || "", span[:start_line] || 0, node.id}
  end
end
