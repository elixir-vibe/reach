defmodule Reach.Visualize do
  @moduledoc "Generates interactive HTML reports from project analysis."

  alias Reach.Visualize.{ControlFlow, Source}

  # ── Public API ──

  def to_graph_json(graph, opts \\ []) do
    %Reach.Visualize.Graph.JSON{
      control_flow: ControlFlow.build(Reach.nodes(graph), graph),
      call_graph: call_graph_data(graph),
      data_flow: data_flow_data(graph, opts)
    }
  end

  def to_json(graph, opts \\ []) do
    graph |> to_graph_json(opts) |> JSON.encode!()
  end

  def makeup_stylesheet do
    if Code.ensure_loaded?(Makeup) do
      Makeup.stylesheet()
    else
      ""
    end
  end

  # ── Call Graph ──

  defp call_graph_data(graph) do
    all_nodes = Reach.nodes(graph)
    call_graph = extract_call_graph(graph)
    call_graph = add_cross_language_edges(call_graph, graph, all_nodes)
    fallback_module = detect_single_module(all_nodes)
    node_map = Map.new(all_nodes, &{&1.id, &1})

    function_nodes = Enum.filter(all_nodes, &(&1.type == :function_def))
    node_to_func = build_node_to_func_map(function_nodes)

    internal_funcs =
      function_nodes
      |> Enum.map(fn function ->
        {function_module(function) || fallback_module, function.meta[:name],
         function.meta[:arity] || 0}
      end)
      |> MapSet.new()

    module_files = module_files(function_nodes, fallback_module)
    plugins = Reach.Plugin.detect()

    clean_edges =
      call_graph
      |> Graph.edges()
      |> Enum.reject(&garbage_call?(&1, plugins))
      |> Enum.map(fn edge ->
        module = call_site_module(edge, node_to_func, node_map) || fallback_module
        src = resolve_nil_module(edge.v1, module)
        tgt = resolve_nil_module(edge.v2, module)
        {src, tgt, edge}
      end)
      |> Enum.reject(fn {src, tgt, edge} ->
        invalid_call_module?(src) or invalid_call_module?(tgt) or src == tgt or
          unresolved_local_call?(src, tgt, edge, internal_funcs, node_map)
      end)
      |> Enum.map(fn {src, tgt, _edge} -> {src, tgt} end)
      |> Enum.uniq()

    # Build module groups
    all_func_ids =
      clean_edges
      |> Enum.flat_map(fn {src, tgt} -> [src, tgt] end)
      |> Enum.uniq()

    modules =
      all_func_ids
      |> Enum.group_by(fn {mod, _, _} -> mod end)
      |> Enum.map(fn {mod, funcs} ->
        %{
          id: safe_module_name(mod),
          name: display_module(mod),
          file: Map.get(module_files, mod),
          functions:
            funcs
            |> Enum.uniq()
            |> Enum.map(fn {_m, f, a} ->
              %{
                id: call_id(mod, f, a),
                name: "#{f}/#{a}",
                arity: a
              }
            end)
            |> Enum.sort_by(& &1.id)
        }
      end)
      |> Enum.sort_by(& &1.id)

    edges =
      clean_edges
      |> Enum.map(fn {{sm, sf, sa}, {tm, tf, ta}} ->
        %{
          id: "call_#{call_id(sm, sf, sa)}_#{call_id(tm, tf, ta)}",
          source: call_id(sm, sf, sa),
          target: call_id(tm, tf, ta),
          color: edge_color(sm, tm)
        }
      end)
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(& &1.id)

    %{modules: modules, edges: edges}
  end

  defp add_cross_language_edges(call_graph, sdg_graph, all_nodes) do
    sdg = Reach.to_graph(sdg_graph)
    node_map = Map.new(all_nodes, &{&1.id, &1})

    cross_edges =
      Graph.edges(sdg)
      |> Enum.filter(fn e ->
        match?(:js_eval, e.label) or match?({:js_call, _}, e.label) or
          match?({:beam_call, _}, e.label)
      end)
      |> Enum.flat_map(fn e ->
        cross_edge_keys(Map.get(node_map, e.v1), Map.get(node_map, e.v2), e.label)
      end)

    Enum.reduce(cross_edges, call_graph, fn {from, to, label}, g ->
      g
      |> Graph.add_vertex(from)
      |> Graph.add_vertex(to)
      |> Graph.add_edge(from, to, label: label)
    end)
  end

  defp edge_color(sm, tm) do
    cond do
      sm == :"<javascript>" or tm == :"<javascript>" -> "#f97316"
      sm == tm -> "#7c3aed"
      true -> "#94a3b8"
    end
  end

  defp cross_edge_keys(nil, _, _), do: []
  defp cross_edge_keys(_, nil, _), do: []

  defp cross_edge_keys(from, to, label) do
    with from_key when from_key != nil <- func_key(from),
         to_key when to_key != nil <- func_key(to) do
      [{from_key, to_key, label}]
    else
      _ -> []
    end
  end

  defp func_key(%{type: :function_def, meta: meta} = function) do
    if mod = function_module(function), do: {mod, meta[:name], meta[:arity] || 0}
  end

  defp func_key(%{type: :call, meta: meta}) do
    {meta[:module], meta[:function], meta[:arity] || 0}
  end

  defp func_key(%{type: :fn}), do: nil
  defp func_key(_), do: nil

  defp function_module(%{meta: meta}) do
    meta[:module] || if meta[:language] == :javascript, do: :"<javascript>"
  end

  @noise_functions MapSet.new([:!, :&&, :||, :|>, :"~~~", :not, :and, :or, :in, :\\])

  defp garbage_call?(edge, plugins) do
    {_target_module, target_function, _target_arity} = edge.v2

    not is_atom(elem(edge.v1, 0)) or
      not is_atom(elem(edge.v2, 0)) or
      target_function in @noise_functions or
      Reach.Plugin.ignore_call_edge?(plugins, edge)
  end

  defp resolve_nil_module({nil, func, arity}, module_name),
    do: {module_name || :_, func, arity}

  defp resolve_nil_module(mfa, _), do: mfa

  defp call_id(mod, func, arity) do
    "#{safe_module_name(mod)}.#{safe_name(func)}/#{arity}"
  end

  defp safe_module_name(nil), do: "_"

  defp safe_module_name(mod) when is_atom(mod) do
    mod |> Atom.to_string() |> String.replace("Elixir.", "") |> sanitize_id()
  end

  defp safe_module_name(mod) when is_binary(mod), do: sanitize_id(mod)
  defp safe_module_name(mod), do: mod |> inspect() |> sanitize_id()

  defp safe_name(name) when is_atom(name), do: name |> Atom.to_string() |> sanitize_id()
  defp safe_name(name), do: name |> to_string() |> sanitize_id()

  defp sanitize_id(s), do: String.replace(s, ~r/[<>":]/, "")

  defp display_module(:"<javascript>"), do: "JavaScript"
  defp display_module(mod), do: safe_module_name(mod)

  # ── Data Flow ──

  defp data_flow_data(graph, opts) do
    taint_results =
      case Keyword.get(opts, :taint) do
        nil -> []
        taint_opts -> Reach.taint_analysis(graph, taint_opts)
      end

    all_nodes = Reach.nodes(graph)
    func_nodes = Enum.filter(all_nodes, &(&1.type == :function_def))
    node_map = Map.new(all_nodes, &{&1.id, &1})
    node_to_func = build_node_to_func_map(func_nodes)

    data_edges =
      Reach.edges(graph)
      |> Enum.filter(&(is_integer(&1.v1) and is_integer(&1.v2) and data_edge?(&1.label)))

    involved_ids =
      data_edges
      |> Enum.flat_map(&[&1.v1, &1.v2])
      |> MapSet.new()

    functions = build_data_flow_nodes(all_nodes, involved_ids, node_to_func, node_map)

    viz_ids = MapSet.new(functions, & &1.id)

    edges =
      data_edges
      |> Enum.map(fn e ->
        %{
          id: "df_#{e.v1}_#{e.v2}",
          source: to_string(e.v1),
          target: to_string(e.v2),
          label: to_string(extract_var_name(e.label) || "data"),
          color: "#16a34a"
        }
      end)
      |> Enum.filter(&(&1.source in viz_ids and &1.target in viz_ids))
      |> Enum.uniq_by(&{&1.source, &1.target})

    taint_paths =
      Enum.map(taint_results, fn result ->
        %{
          source: node_label_short(result.source),
          sink: node_label_short(result.sink),
          path: Enum.map(result.path, &node_label_short/1)
        }
      end)

    %{functions: functions, edges: edges, taint_paths: taint_paths}
  end

  defp data_edge?({:data, _}), do: true

  defp data_edge?(:match_binding), do: true

  defp data_edge?(_), do: false

  defp extract_var_name({:data, var}), do: var
  defp extract_var_name(_), do: nil

  defp build_data_flow_nodes(all_nodes, involved_ids, node_to_func, node_map) do
    for node <- all_nodes,
        MapSet.member?(involved_ids, node.id),
        node.type not in [:module_def, :function_def, :clause],
        node.source_span[:start_line] != nil do
      function_id = Map.get(node_to_func, node.id)
      function = if function_id, do: Map.get(node_map, function_id)

      function_prefix =
        if function, do: "#{function.meta[:name]}/#{function.meta[:arity]} ", else: ""

      module = if function, do: function_module(function)
      file = node.source_span[:file] || source_file(function)
      line = node.source_span[:start_line]

      %{
        id: to_string(node.id),
        function_id: if(function_id, do: to_string(function_id)),
        label: "#{function_prefix}L#{line}: #{ir_node_label(node)}",
        module: if(module, do: display_module(module)),
        file: file,
        start_line: line,
        source_html: Source.highlight_line(file, line)
      }
    end
  end

  defp source_file(nil), do: nil
  defp source_file(function), do: get_in(function, [Access.key(:source_span), Access.key(:file)])

  defp ir_node_label(%{type: :var, meta: %{name: name}}), do: to_string(name)
  defp ir_node_label(%{type: :call, meta: meta}), do: to_string(meta[:function]) <> "(...)"
  defp ir_node_label(%{type: :match}), do: "="
  defp ir_node_label(%{type: :literal, meta: %{value: v}}), do: inspect(v)
  defp ir_node_label(%{type: type}), do: to_string(type)

  # ── Helpers ──

  defp build_node_to_func_map(func_nodes) do
    func_ids = MapSet.new(func_nodes, & &1.id)

    for func <- func_nodes,
        child <- Reach.IR.all_nodes(func),
        child.id not in func_ids,
        into: %{} do
      {child.id, func.id}
    end
  end

  defp extract_call_graph(%Reach.Project{call_graph: cg}), do: cg
  defp extract_call_graph(%Reach.SystemDependence{call_graph: cg}), do: cg

  defp detect_single_module(all_nodes) do
    modules =
      all_nodes
      |> Enum.flat_map(fn
        %{type: :module_def, meta: %{name: name}} -> [name]
        %{type: :function_def} = function -> List.wrap(function_module(function))
        _node -> []
      end)
      |> Enum.uniq()

    case modules do
      [module] -> module
      _multiple_or_missing -> nil
    end
  end

  defp module_files(function_nodes, fallback_module) do
    function_nodes
    |> Enum.reduce(%{}, fn function, files ->
      module = function_module(function) || fallback_module
      file = get_in(function, [Access.key(:source_span), Access.key(:file)])

      if module && file do
        Map.update(files, module, file, &min(&1, file))
      else
        files
      end
    end)
  end

  defp call_site_module(%{label: {:call, node_id}}, node_to_func, nodes) do
    with function_id when not is_nil(function_id) <- Map.get(node_to_func, node_id),
         %{type: :function_def} = function <- Map.get(nodes, function_id) do
      function_module(function)
    else
      _missing_function -> nil
    end
  end

  defp call_site_module(_edge, _node_to_func, _nodes), do: nil

  defp invalid_call_module?({module, _, _}), do: not is_atom(module)

  defp unresolved_local_call?({module, _, _}, {module, _, _} = target, edge, internal, nodes) do
    target not in internal and local_call_edge?(edge, nodes)
  end

  defp unresolved_local_call?(_source, _target, _edge, _internal, _nodes), do: false

  defp local_call_edge?(%{label: {:call, node_id}}, nodes) do
    case Map.get(nodes, node_id) do
      %{type: :call, meta: meta} -> is_nil(meta[:module])
      _node -> false
    end
  end

  defp local_call_edge?(_edge, _nodes), do: false

  defp node_label_short(%{type: :call, meta: meta}) do
    case meta[:module] do
      nil -> "#{meta[:function]}/#{meta[:arity]}"
      mod -> "#{inspect(mod)}.#{meta[:function]}/#{meta[:arity]}"
    end
  end

  defp node_label_short(%{meta: %{name: name}}), do: to_string(name)
  defp node_label_short(%{type: type}), do: to_string(type)
end
