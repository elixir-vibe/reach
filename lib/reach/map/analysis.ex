defmodule Reach.Map.Analysis do
  @moduledoc "Computes project-wide summaries including modules, hotspots, coupling, effects, depth, and data flow."

  alias Reach.Analysis
  alias Reach.ControlFlow
  alias Reach.Dominator
  alias Reach.Effects
  alias Reach.IR
  alias Reach.IR.Helpers, as: IRHelpers

  alias Reach.Map.{
    Boundary,
    Coupling,
    Cycle,
    DataFunction,
    DataSummary,
    DepthMetric,
    EffectCall,
    EffectRow,
    EffectSourceRow,
    EffectSummary,
    Hotspot,
    ModuleCoupling,
    ModuleMetric,
    Summary,
    UnknownCall,
    XrefEdge
  }

  alias Reach.Project.Query
  alias Reach.Source.Suppression

  @xref_variable_sample_limit 5

  def summary(project, path) do
    funcs = function_defs(project, path)
    modules = module_defs(project, path)
    effects = effect_counts(funcs, project.plugins)

    Summary.new(
      modules: length(modules),
      functions: length(funcs),
      call_graph_vertices: Graph.num_vertices(project.call_graph),
      call_graph_edges: Graph.num_edges(project.call_graph),
      graph_nodes: map_size(project.nodes),
      graph_edges: Graph.num_edges(project.graph),
      effects: Map.new(effects, fn {effect, count} -> {to_string(effect), count} end),
      suppressions: Suppression.project_summary(project, path)
    )
  end

  def section_data(project, :modules, opts, path) do
    project
    |> module_metrics(path)
    |> sort_modules(opts[:sort])
    |> Enum.take(opts[:top] || 50)
  end

  def section_data(project, :hotspots, opts, path) do
    project
    |> hotspot_metrics(path)
    |> Enum.take(opts[:top] || 20)
  end

  def section_data(project, :coupling, opts, path) do
    coupling = coupling_metrics(project, path)

    top = opts[:top]

    modules =
      coupling.modules
      |> maybe_filter_orphans(opts[:orphans])
      |> sort_coupling(opts[:sort])
      |> Enum.take(top || 50)

    Coupling.new(
      modules: modules,
      cycles: coupling.cycles |> Enum.take(top || 20)
    )
  end

  def section_data(project, :effects, opts, path) do
    project
    |> call_nodes(path, opts[:module])
    |> effect_summary(opts[:top] || 20, project.plugins)
  end

  def section_data(project, :boundaries, opts, path) do
    min = opts[:min] || 2

    project
    |> function_defs(path)
    |> Enum.flat_map(&boundary_candidate(&1, min, project.plugins))
    |> Enum.sort_by(fn {func, effects} -> {-length(effects), location_sort(func)} end)
    |> Enum.take(opts[:top] || 20)
    |> Enum.map(fn {func, effects} ->
      mfa = {func.meta[:module], func.meta[:name], func.meta[:arity]}
      module = func.meta[:module] && inspect(func.meta[:module])
      function = "#{func.meta[:name]}/#{func.meta[:arity]}"

      Boundary.new(
        module: module,
        function: function,
        display_function: IRHelpers.func_id_to_string(mfa),
        file: func.source_span && func.source_span.file,
        line: func.source_span && func.source_span.start_line,
        effects: effects,
        calls: effect_calls(func, project.plugins)
      )
    end)
  end

  def section_data(project, :depth, opts, path) do
    project
    |> function_defs(path)
    |> Enum.flat_map(&depth_metric/1)
    |> Enum.sort_by(& &1.depth, :desc)
    |> Enum.take(opts[:top] || 20)
  end

  def section_data(project, :data, opts, path) do
    data_edges =
      project.graph
      |> Graph.edges()
      |> Enum.filter(&Analysis.data_edge?/1)

    func_index = Query.function_index(project).node_to_function
    edge_counts = data_edge_counts(data_edges, func_index)
    top = opts[:top] || 20

    top_functions =
      project
      |> function_defs(path)
      |> Enum.map(fn func ->
        id = function_id(func)

        DataFunction.new(
          function: func_id(func),
          file: func.source_span && func.source_span.file,
          line: func.source_span && func.source_span.start_line,
          data_edges: Map.get(edge_counts, id, 0)
        )
      end)
      |> Enum.sort_by(& &1.data_edges, :desc)
      |> Enum.take(top)

    DataSummary.new(
      total_data_edges: length(data_edges),
      top_functions: top_functions,
      cross_function_edges: cross_function_edges(project, data_edges, top, func_index)
    )
  end

  def section_data(project, :xref, opts, path), do: section_data(project, :data, opts, path)

  @doc "Returns coupling metrics for every project module."
  @spec module_coupling(Reach.Project.t()) :: [Reach.Map.ModuleCoupling.t()]
  def module_coupling(project) do
    project
    |> coupling_metrics(nil)
    |> Map.fetch!(:modules)
  end

  defp function_defs(project, path) do
    for {_id, node} <- project.nodes,
        node.type == :function_def and Query.file_matches?(span_file(node), path),
        do: node
  end

  defp call_nodes(project, path, module_filter) do
    project
    |> function_defs(path)
    |> filter_functions_by_module(module_filter)
    |> Enum.flat_map(fn function ->
      function
      |> IR.all_nodes()
      |> Enum.filter(&(&1.type == :call))
    end)
    |> Enum.uniq_by(& &1.id)
  end

  defp filter_functions_by_module(functions, nil), do: functions

  defp filter_functions_by_module(functions, module_filter) do
    Enum.filter(functions, fn function ->
      function.meta[:module] && to_string(function.meta[:module]) =~ module_filter
    end)
  end

  defp module_defs(project, path) do
    for {_id, node} <- project.nodes,
        node.type == :module_def and Query.file_matches?(span_file(node), path),
        do: node
  end

  defp module_metrics(project, path) do
    modules = module_defs(project, path)
    internal = MapSet.new(module_defs(project, nil), & &1.meta[:name])
    dependencies = module_dependency_map(modules, internal)
    dependents = invert_deps(dependencies)

    Enum.map(modules, fn module ->
      funcs = module |> IR.all_nodes() |> Enum.filter(&(&1.type == :function_def))

      public_count = Enum.count(funcs, &(&1.meta[:kind] == :def))
      private_count = Enum.count(funcs, &(&1.meta[:kind] in [:defp, :defmacrop]))
      macro_count = Enum.count(funcs, &(&1.meta[:kind] == :defmacro))
      total_complexity = Enum.sum_by(funcs, &branch_count/1)
      callbacks = detect_callbacks(module |> IR.all_nodes(), project.plugins)

      ModuleMetric.new(
        name: inspect(module.meta[:name]),
        file: span_file(module),
        functions: length(funcs),
        public: public_count,
        private: private_count,
        complexity: total_complexity,
        public_count: public_count,
        private_count: private_count,
        macro_count: macro_count,
        total_functions: length(funcs),
        total_complexity: total_complexity,
        biggest_function: biggest_function(funcs),
        callbacks: callbacks,
        fan_in: dependencies_count(dependents, module.meta[:name]),
        fan_out: dependencies_count(dependencies, module.meta[:name])
      )
    end)
    |> Enum.reject(&(&1.functions == 0))
  end

  defp hotspot_metrics(project, path) do
    caller_counts = direct_caller_counts(project.call_graph)

    project
    |> function_defs(path)
    |> Enum.map(fn func ->
      callers = caller_count(func, caller_counts)
      branches = branch_count(func)

      mfa = {func.meta[:module], func.meta[:name], func.meta[:arity]}
      module = func.meta[:module] && inspect(func.meta[:module])
      function = "#{func.meta[:name]}/#{func.meta[:arity]}"

      Hotspot.new(
        module: module,
        function: function,
        display_function: IRHelpers.func_id_to_string(mfa),
        file: span_file(func),
        line: func.source_span && func.source_span.start_line,
        branches: branches,
        callers: callers,
        score: branches * callers,
        clauses: IRHelpers.clause_labels(func)
      )
    end)
    |> Enum.filter(&(&1.score > 0))
    |> Enum.sort_by(& &1.score, :desc)
  end

  defp coupling_metrics(project, path) do
    module_nodes = module_defs(project, path)
    internal = MapSet.new(module_defs(project, nil), & &1.meta[:name])
    deps = module_dependency_map(module_nodes, internal)
    afferent = invert_deps(deps)

    modules =
      Enum.map(module_nodes, fn module ->
        name = module.meta[:name]
        ce = Map.get(deps, name, []) |> length()
        ca = Map.get(afferent, name, []) |> length()
        total = ca + ce

        ModuleCoupling.new(
          name: inspect(name),
          file: span_file(module),
          afferent: ca,
          efferent: ce,
          instability: if(total == 0, do: 0.0, else: Float.round(ce / total, 2))
        )
      end)

    cycles =
      deps
      |> module_dependency_graph()
      |> Reach.GraphAlgorithms.cycle_components(&canonical_module_cycle/1)
      |> Enum.map(&Cycle.new(modules: &1))

    Coupling.new(modules: modules, cycles: cycles)
  end

  defp direct_caller_counts(call_graph) do
    call_graph
    |> Graph.edges()
    |> Enum.filter(&(Query.mfa?(&1.v1) and Query.mfa?(&1.v2)))
    |> Enum.reduce(%{}, fn edge, acc ->
      Map.update(acc, edge.v2, MapSet.new([edge.v1]), &MapSet.put(&1, edge.v1))
    end)
    |> Map.new(fn {target, callers} -> {target, MapSet.size(callers)} end)
  end

  defp caller_count(func, caller_counts) do
    func
    |> function_vertex()
    |> function_variants()
    |> Enum.sum_by(&Map.get(caller_counts, &1, 0))
  end

  defp function_variants({module, function, arity}) do
    [{nil, function, arity}, {module, function, arity}]
    |> Enum.uniq()
  end

  defp module_dependency_map(module_nodes, internal) do
    seed = Map.new(module_nodes, &{&1.meta[:name], []})

    module_nodes
    |> Enum.reduce(seed, fn module, dependencies ->
      module
      |> IR.all_nodes()
      |> Enum.filter(&(&1.type == :call and &1.meta[:kind] == :remote and &1.meta[:module]))
      |> Enum.reduce(dependencies, &add_module_dependency(&1, &2, module.meta[:name], internal))
    end)
    |> Map.new(fn {module, deps} -> {module, deps |> Enum.uniq() |> Enum.sort()} end)
  end

  defp add_module_dependency(call, acc, caller, internal) do
    callee = call.meta[:module]

    if caller && callee && caller != callee && MapSet.member?(internal, callee) do
      Map.update(acc, caller, [callee], &[callee | &1])
    else
      acc
    end
  end

  defp invert_deps(deps) do
    Enum.reduce(deps, %{}, fn {module, module_deps}, acc ->
      Enum.reduce(module_deps, acc, fn dep, inner ->
        Map.update(inner, dep, [module], &[module | &1])
      end)
    end)
  end

  defp module_dependency_graph(deps) do
    Enum.reduce(deps, Graph.new(type: :directed), fn {module, module_deps}, graph ->
      Enum.reduce(module_deps, Graph.add_vertex(graph, module), fn dep, graph ->
        Graph.add_edge(graph, module, dep)
      end)
    end)
  end

  defp canonical_module_cycle(cycle) do
    cycle
    |> Enum.map(&inspect/1)
    |> Enum.sort()
  end

  defp effect_counts(functions, plugins) do
    functions
    |> Enum.flat_map(&function_effects(&1, plugins))
    |> Enum.frequencies()
    |> Enum.sort_by(fn {effect, _count} -> to_string(effect) end)
  end

  defp effect_summary(call_nodes, top, plugins) do
    classified_calls =
      Enum.map(call_nodes, fn node ->
        {node, Effects.classify_with_provenance(node, plugins)}
      end)

    total = length(classified_calls)

    distribution =
      classified_calls
      |> Enum.map(fn {_node, classification} -> classification.effect end)
      |> Enum.frequencies()
      |> Enum.sort_by(&elem(&1, 1), :desc)

    sources =
      classified_calls
      |> Enum.map(fn {_node, classification} ->
        {classification.source, classification.classifier, classification.confidence}
      end)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {{source, classifier, confidence}, count} ->
        {-count, to_string(source), inspect(classifier), to_string(confidence)}
      end)
      |> Enum.map(fn {{source, classifier, confidence}, count} ->
        EffectSourceRow.new(
          source: source,
          classifier: if(classifier, do: inspect(classifier)),
          confidence: confidence,
          count: count,
          ratio: Float.round(count / max(total, 1), 3)
        )
      end)

    unknown_calls =
      classified_calls
      |> Enum.filter(fn {_node, classification} -> classification.effect == :unknown end)
      |> Enum.reject(fn {node, _classification} ->
        is_nil(node.meta[:function]) or node.meta[:function] in [:__aliases__, :{}]
      end)
      |> Enum.map(fn {node, classification} ->
        {
          unknown_call_module(node),
          node.meta[:function],
          node.meta[:arity],
          node.meta[:kind] || :unknown,
          classification.reason
        }
      end)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {{module, function, arity, kind, reason}, count} ->
        {-count, module, to_string(function), arity || -1, to_string(kind), to_string(reason)}
      end)
      |> Enum.take(top)
      |> Enum.map(fn {{module, function, arity, kind, reason}, count} ->
        UnknownCall.new(
          module: module,
          function: to_string(function),
          arity: arity,
          kind: kind,
          reason: reason,
          count: count
        )
      end)

    EffectSummary.new(
      total_calls: total,
      distribution:
        Enum.map(distribution, fn {effect, count} ->
          EffectRow.new(
            effect: effect,
            count: count,
            ratio: Float.round(count / max(total, 1), 3)
          )
        end),
      sources: sources,
      unknown_calls: unknown_calls
    )
  end

  defp unknown_call_module(%IR.Node{meta: %{kind: :local} = meta}) do
    case meta[:owner_module] do
      module when is_atom(module) -> inspect(module)
      _unknown -> "local"
    end
  end

  defp unknown_call_module(%IR.Node{meta: meta}) do
    case meta[:module] do
      module when not is_nil(module) -> inspect(module)
      _unknown -> "unresolved"
    end
  end

  defp function_effects(func, plugins) do
    func
    |> IR.all_nodes()
    |> Enum.map(&Effects.classify(&1, plugins))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp depth_metric(func) do
    cfg = ControlFlow.build(func)
    idom = Dominator.idom(cfg, :entry)
    tree = Dominator.tree(idom)
    depth = max_tree_depth(tree, :entry, 0, MapSet.new())

    if depth > 0 do
      [
        DepthMetric.new(
          module: inspect(func.meta[:module]),
          function: func_id(func),
          depth: depth,
          clauses: IRHelpers.clause_labels(func),
          file: span_file(func),
          line: func.source_span && func.source_span.start_line,
          branch_count: branch_count(func)
        )
      ]
    else
      []
    end
  rescue
    _error in [ArgumentError, File.Error, MatchError] -> []
  end

  defp max_tree_depth(tree, node, depth, visited) do
    if MapSet.member?(visited, node) do
      depth
    else
      visited = MapSet.put(visited, node)

      tree
      |> Graph.out_neighbors(node)
      |> Enum.reduce(depth, fn child, acc ->
        max(max_tree_depth(tree, child, depth + 1, visited), acc)
      end)
    end
  end

  defp data_edge_counts(data_edges, func_index) do
    Enum.reduce(data_edges, %{}, fn edge, counts ->
      source_func = Map.get(func_index, edge.v1)
      target_func = Map.get(func_index, edge.v2)

      counts
      |> increment_data_edge_count(source_func)
      |> increment_data_edge_count(if(target_func == source_func, do: nil, else: target_func))
    end)
  end

  defp increment_data_edge_count(counts, nil), do: counts
  defp increment_data_edge_count(counts, func), do: Map.update(counts, func, 1, &(&1 + 1))

  defp cross_function_edges(project, data_edges, top, func_index) do
    data_edges
    |> Enum.flat_map(fn edge ->
      source_func = Map.get(func_index, edge.v1)
      target_func = Map.get(func_index, edge.v2)
      source_node = Map.get(project.nodes, edge.v1)
      target_node = Map.get(project.nodes, edge.v2)

      if source_func && target_func && source_func != target_func do
        [
          %{
            from_func: source_func,
            to_func: target_func,
            label: normalize_label(edge.label),
            from_node: node_summary(source_node),
            to_node: node_summary(target_node)
          }
        ]
      else
        []
      end
    end)
    |> Enum.group_by(&{&1.from_func, &1.to_func})
    |> Enum.map(fn {{from, to}, edges} ->
      labels = edges |> Enum.map(& &1.label) |> Enum.frequencies()

      variables =
        edges
        |> Enum.flat_map(fn edge -> [edge.from_node, edge.to_node] end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.take(@xref_variable_sample_limit)

      XrefEdge.new(
        from: func_id_tuple(from),
        to: func_id_tuple(to),
        edges: Enum.reduce(labels, 0, fn {_k, v}, acc -> acc + v end),
        labels: labels,
        variables: variables
      )
    end)
    |> Enum.sort_by(& &1.edges, :desc)
    |> Enum.take(top)
  end

  defp normalize_label({label, _}), do: label
  defp normalize_label(label), do: label

  defp node_summary(nil), do: nil
  defp node_summary(%{type: :var, meta: %{name: name}}), do: to_string(name)
  defp node_summary(%{type: :call, meta: %{function: function}}), do: to_string(function)
  defp node_summary(%{type: :literal, meta: %{value: value}}), do: inspect(value)
  defp node_summary(%{type: type}), do: to_string(type)

  defp branch_count(func) do
    func
    |> IR.all_nodes()
    |> Enum.count(
      &(&1.type in [:case, :receive, :try] or
          (&1.type == :binary_op and &1.meta[:operator] in [:and, :or, :&&, :||]))
    )
  end

  defp biggest_function([]), do: nil

  defp biggest_function(funcs) do
    func = Enum.max_by(funcs, &branch_count/1)
    "#{func.meta[:name]}/#{func.meta[:arity]} (#{branch_count(func)})"
  end

  defp detect_callbacks(nodes, plugins) do
    callbacks =
      nodes
      |> Enum.filter(&callback_function?(&1, plugins))
      |> Enum.map(& &1.meta[:name])
      |> Enum.uniq()

    case infer_behaviour(callbacks, plugins) do
      nil -> callbacks
      behaviour -> [behaviour | callbacks]
    end
  end

  defp callback_function?(node, plugins) do
    node.type == :function_def and
      (node.meta[:name] in [:init, :handle_call, :handle_cast, :handle_info, :handle_continue] or
         Reach.Plugin.expected_effect_boundary?(
           plugins,
           node.meta[:module],
           node.meta[:name],
           node.meta[:arity]
         ))
  end

  defp infer_behaviour(callbacks, plugins) do
    if :handle_call in callbacks or :handle_cast in callbacks do
      "GenServer"
    else
      Reach.Plugin.behaviour_label(plugins, callbacks)
    end
  end

  defp boundary_candidate(func, min, plugins) do
    effects = function_effects(func, plugins) -- [:pure, :unknown]

    if length(effects) >= min, do: [{func, effects}], else: []
  end

  defp dependencies_count(dependencies, module) do
    dependencies |> Map.get(module, []) |> length()
  end

  defp function_vertex(func), do: {func.meta[:module], func.meta[:name], func.meta[:arity]}

  defp effect_calls(func, plugins) do
    func
    |> IR.all_nodes()
    |> Enum.filter(&(&1.type == :call))
    |> Enum.reject(&(Effects.classify(&1, plugins) in [:pure, :unknown]))
    |> Enum.map(fn call ->
      EffectCall.new(effect: Effects.classify(call, plugins), call: IRHelpers.call_name(call))
    end)
    |> Enum.uniq_by(& &1.call)
    |> Enum.sort_by(& &1.effect)
  end

  defp sort_modules(modules, "functions"), do: Enum.sort_by(modules, & &1.total_functions, :desc)

  defp sort_modules(modules, "complexity"),
    do: Enum.sort_by(modules, & &1.total_complexity, :desc)

  defp sort_modules(modules, _), do: Enum.sort_by(modules, & &1.name)

  defp sort_coupling(modules, "afferent"), do: Enum.sort_by(modules, & &1.afferent, :desc)
  defp sort_coupling(modules, "efferent"), do: Enum.sort_by(modules, & &1.efferent, :desc)
  defp sort_coupling(modules, _), do: Enum.sort_by(modules, & &1.instability, :desc)

  defp maybe_filter_orphans(modules, true),
    do: Enum.filter(modules, &(&1.afferent == 0 and &1.efferent > 0))

  defp maybe_filter_orphans(modules, _), do: modules

  defp function_id(func), do: {func.meta[:module], func.meta[:name], func.meta[:arity]}

  defp func_id(func), do: IRHelpers.func_id_to_string(function_id(func))

  defp func_id_tuple({module, name, arity}),
    do: IRHelpers.func_id_to_string({module, name, arity})

  defp span_file(node), do: node.source_span && node.source_span.file

  defp location_sort(func),
    do: {span_file(func) || "", (func.source_span && func.source_span.start_line) || 0}
end
