defmodule Reach.Check.Architecture do
  @moduledoc "Validates `.reach.exs` architecture policies against project structure."

  alias Reach.Check.Violation
  alias Reach.Config
  alias Reach.Effects
  alias Reach.IR

  def run(project, config) do
    violations =
      case Config.from_terms(config) do
        {:ok, normalized} -> violations(project, normalized)
        {:error, errors} -> Enum.map(errors, &Config.Error.to_violation/1)
      end

    %{
      config: ".reach.exs",
      status: if(violations == [], do: "ok", else: "failed"),
      violations: violations
    }
  end

  def violations(project, config) do
    graph = layer_graph(project, config)

    source_policy_violations(project, config) ++
      layer_coverage_violations(project, config) ++
      dependency_violations(project, config, graph) ++
      public_boundary_violations(project, config) ++
      forbidden_call_violations(project, config) ++
      layer_cycle_violations(graph) ++
      effect_policy_violations(project, config)
  end

  def config_violations(config) do
    config
    |> Config.errors()
    |> Enum.map(&Config.Error.to_violation/1)
  end

  def layer_graph(project, config) do
    config = Config.normalize(config)
    layers = config.layers
    module_by_file = module_by_file(project)

    edges =
      for({_id, node} <- project.nodes, remote_call?(node), do: node)
      |> Enum.flat_map(fn node ->
        caller_module = node.source_span && Map.get(module_by_file, node.source_span.file)
        callee_module = node.meta[:module]

        with caller when not is_nil(caller) <- caller_module,
             callee when not is_nil(callee) <- callee_module,
             caller_layer when not is_nil(caller_layer) <- module_layer(caller, layers),
             callee_layer when not is_nil(callee_layer) <- module_layer(callee, layers),
             true <- caller_layer != callee_layer do
          [%{from: caller_layer, to: callee_layer, node: node, caller: caller, callee: callee}]
        else
          _ -> []
        end
      end)

    %{edges: edges, adjacency: adjacency(edges)}
  end

  def dependency_violations(_project, config, layer_graph) do
    config = Config.normalize(config)

    layer_graph.edges
    |> Enum.filter(&dependency_violation_edge?(&1, config.deps))
    |> Enum.map(fn edge ->
      edge
      |> edge_violation_attrs()
      |> Map.put(:type, :forbidden_dependency)
      |> Violation.new()
    end)
  end

  def module_by_file(project) do
    for {_id, node} <- project.nodes,
        node.type == :module_def and node.source_span,
        into: %{},
        do: {node.source_span.file, node.meta[:name]}
  end

  def module_matches_any?(module, patterns) do
    name = inspect(module)
    Enum.any?(patterns, &glob_match?(name, to_string(&1)))
  end

  def glob_match?(value, pattern) do
    pattern_regex =
      pattern
      |> Regex.escape()
      |> String.replace("\\*\\*", ".*")
      |> String.replace("\\*", "[^/]*")

    Regex.match?(~r/^#{pattern_regex}$/, value)
  end

  def function_effects(func) do
    func
    |> IR.all_nodes()
    |> Enum.map(&Effects.classify/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def concrete_effects(func), do: function_effects(func) -- [:pure, :unknown, :exception]

  defp source_policy_violations(project, config) do
    config = Config.normalize(config)

    forbidden_module_violations(project, List.wrap(config.source.forbidden_modules)) ++
      forbidden_file_violations(project, List.wrap(config.source.forbidden_files))
  end

  defp forbidden_module_violations(_project, []), do: []

  defp forbidden_module_violations(project, patterns) do
    for({_id, node} <- project.nodes, forbidden_module?(node, patterns), do: node)
    |> Enum.map(fn node ->
      Violation.new(
        type: :forbidden_module,
        module: inspect(node.meta[:name]),
        file: node.source_span.file,
        line: node.source_span.start_line,
        rule: "configured forbidden module"
      )
    end)
  end

  defp forbidden_module?(node, patterns) do
    node.type == :module_def and not is_nil(node.source_span) and
      module_matches_any?(node.meta[:name], patterns)
  end

  defp forbidden_file_violations(_project, []), do: []

  defp forbidden_file_violations(project, patterns) do
    for({_id, node} <- project.nodes, node.source_span, do: node.source_span.file)
    |> Enum.uniq()
    |> Enum.filter(fn file -> Enum.any?(patterns, &glob_match?(file, to_string(&1))) end)
    |> Enum.map(fn file ->
      Violation.new(
        type: :forbidden_file,
        file: file,
        rule: "configured forbidden file"
      )
    end)
  end

  defp adjacency(edges) do
    Enum.reduce(edges, %{}, fn edge, acc ->
      Map.update(acc, edge.from, MapSet.new([edge.to]), &MapSet.put(&1, edge.to))
    end)
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp public_boundary_violations(project, config) do
    config = Config.normalize(config)
    public_api = List.wrap(config.boundaries.public)
    internal = List.wrap(config.boundaries.internal)
    internal_callers = config.boundaries.internal_callers
    module_by_file = module_by_file(project)

    for({_id, node} <- project.nodes, remote_call?(node), do: node)
    |> Enum.flat_map(fn node ->
      caller = node.source_span && Map.get(module_by_file, node.source_span.file)
      callee = node.meta[:module]

      cond do
        caller == nil or callee == nil ->
          []

        public_api != [] and top_level_api_call?(caller, callee, public_api, internal) ->
          [
            Violation.new(
              type: :public_api_boundary,
              caller_module: inspect(caller),
              callee_module: inspect(callee),
              file: node.source_span.file,
              line: node.source_span.start_line,
              call: "#{inspect(callee)}.#{node.meta[:function]}/#{node.meta[:arity]}",
              rule: "calls into non-public API module"
            )
          ]

        internal != [] and internal_call_violation?(caller, callee, internal, internal_callers) ->
          [
            Violation.new(
              type: :internal_boundary,
              caller_module: inspect(caller),
              callee_module: inspect(callee),
              file: node.source_span.file,
              line: node.source_span.start_line,
              call: "#{inspect(callee)}.#{node.meta[:function]}/#{node.meta[:arity]}",
              rule: "caller is not allowed to call configured internal module"
            )
          ]

        true ->
          []
      end
    end)
  end

  defp forbidden_call_violations(project, config) do
    config = Config.normalize(config)
    rules = config.calls.forbidden
    module_by_file = module_by_file(project)

    for({_id, node} <- project.nodes, remote_call?(node), do: node)
    |> Enum.flat_map(&forbidden_call_violations_for_node(&1, rules, module_by_file))
  end

  defp forbidden_call_violations_for_node(node, rules, module_by_file) do
    caller = node.source_span && Map.get(module_by_file, node.source_span.file)
    call = remote_call_name(node)

    rules
    |> Enum.filter(&forbidden_call_rule_matches?(&1, caller, call))
    |> Enum.map(fn _rule ->
      Violation.new(
        type: :forbidden_call,
        caller_module: inspect(caller),
        call: call,
        file: node.source_span.file,
        line: node.source_span.start_line,
        rule: "configured forbidden call"
      )
    end)
  end

  defp forbidden_call_rule_matches?(_rule, nil, _call), do: false

  defp forbidden_call_rule_matches?(rule, caller, call) do
    {caller_patterns, call_patterns, except_patterns} = forbidden_call_rule(rule)

    module_matches_any?(caller, List.wrap(caller_patterns)) and
      not module_matches_any?(caller, List.wrap(except_patterns)) and
      call_matches_any?(call, List.wrap(call_patterns))
  end

  defp forbidden_call_rule({caller_patterns, call_patterns}),
    do: {caller_patterns, call_patterns, []}

  defp forbidden_call_rule({caller_patterns, call_patterns, opts}) do
    {caller_patterns, call_patterns, Keyword.get(opts, :except, [])}
  end

  defp remote_call_name(node) do
    module = node.meta[:module] |> inspect() |> String.replace_leading("Elixir.", "")
    function = node.meta[:function]
    arity = node.meta[:arity]
    "#{module}.#{function}/#{arity}"
  end

  defp call_matches_any?(call, patterns) do
    Enum.any?(patterns, fn pattern ->
      pattern = to_string(pattern)
      glob_match?(call, pattern) or glob_match?(call_without_arity(call), pattern)
    end)
  end

  defp call_without_arity(call), do: call |> String.split("/", parts: 2) |> List.first()

  defp top_level_api_call?(caller, callee, public_api, internal) do
    public_api
    |> Enum.map(&public_api_namespace/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.any?(fn namespace ->
      module_under_namespace?(callee, namespace) and
        not module_under_namespace?(caller, namespace) and
        not module_matches_any?(callee, public_api) and
        not module_matches_any?(callee, internal)
    end)
  end

  defp internal_call_violation?(caller, callee, internal, internal_callers) do
    module_matches_any?(callee, internal) and
      not allowed_internal_caller?(caller, callee, internal_callers)
  end

  defp allowed_internal_caller?(caller, callee, internal_callers) do
    matching_rule =
      Enum.find(internal_callers, fn {internal_pattern, _caller_patterns} ->
        module_matches_any?(callee, [internal_pattern])
      end)

    case matching_rule do
      {_internal_pattern, caller_patterns} ->
        module_matches_any?(caller, List.wrap(caller_patterns))

      nil ->
        module_namespace(caller) == module_namespace(callee)
    end
  end

  defp public_api_namespace(pattern) do
    pattern
    |> to_string()
    |> String.replace_suffix(".*", "")
    |> String.trim_trailing("*")
    |> String.trim_trailing(".")
    |> case do
      "" -> nil
      namespace -> namespace
    end
  end

  defp module_under_namespace?(module, namespace) do
    name = module_name(module)
    name == namespace or String.starts_with?(name, namespace <> ".")
  end

  defp module_namespace(module) do
    module
    |> module_name()
    |> String.split(".", parts: 2)
    |> List.first()
  end

  defp module_name(module) do
    module
    |> Atom.to_string()
    |> String.replace_leading("Elixir.", "")
  end

  defp layer_cycle_violations(%{adjacency: adjacency, edges: edges}) do
    adjacency
    |> layer_cycle_components()
    |> Enum.map(fn cycle ->
      Violation.new(type: :layer_cycle, layers: cycle, edges: cycle_edge_witnesses(cycle, edges))
    end)
  end

  defp layer_cycle_components(adjacency) do
    adjacency
    |> Enum.reduce(Graph.new(type: :directed), fn {layer, deps}, graph ->
      Enum.reduce(deps, Graph.add_vertex(graph, layer), fn dep, graph ->
        Graph.add_edge(graph, layer, dep)
      end)
    end)
    |> Reach.GraphAlgorithms.cycle_components(&canonical_cycle/1)
  end

  defp canonical_cycle(cycle), do: Enum.sort(cycle)

  defp effect_policy_violations(project, config) do
    config = Config.normalize(config)
    module_by_file = module_by_file(project)

    for({_id, node} <- project.nodes, node.type == :function_def, do: node)
    |> Enum.flat_map(&effect_policy_violation(&1, config, module_by_file))
  end

  defp effect_policy_violation(func, config, module_by_file) do
    module =
      func.meta[:module] || (func.source_span && Map.get(module_by_file, func.source_span.file))

    with allowed when not is_nil(allowed) <- allowed_effects_for(module, config),
         false <- allowed == :any,
         effects <- function_effects(func),
         disallowed when disallowed != [] <- effects -- allowed do
      [
        Violation.new(
          type: :effect_policy,
          module: inspect(module),
          function: "#{func.meta[:name]}/#{func.meta[:arity]}",
          allowed_effects: Enum.map(allowed, &to_string/1),
          actual_effects: Enum.map(effects, &to_string/1),
          disallowed_effects: Enum.map(disallowed, &to_string/1),
          file: func.source_span && func.source_span.file,
          line: func.source_span && func.source_span.start_line
        )
      ]
    else
      _ -> []
    end
  end

  defp allowed_effects_for(module, config) do
    Enum.find_value(config.effects.allowed, fn {pattern, effects} ->
      if module_matches_any?(module, [pattern]), do: effects
    end) || allowed_effects_for_layer(module, config)
  end

  defp allowed_effects_for_layer(module, config) do
    with layer when not is_nil(layer) <- module_layer(module, config.layers) do
      Keyword.get(config.effects.by_layer, layer)
    end
  end

  def remote_call?(node) do
    node.type == :call and node.meta[:kind] == :remote and is_atom(node.meta[:module]) and
      node.meta[:function] not in [:__aliases__, :{}]
  end

  defp layer_coverage_violations(project, config) do
    config = Config.normalize(config)

    case config.checks.layer_coverage do
      nil ->
        []

      coverage ->
        project_modules(project)
        |> Enum.reject(&module_matches_any?(&1, coverage.ignore))
        |> Enum.flat_map(&layer_coverage_violations_for_module(&1, config.layers, coverage))
    end
  end

  defp layer_coverage_violations_for_module(module, layers, coverage) do
    matches = matching_layers(layers, module)

    cond do
      coverage.require_all_modules and matches == [] ->
        [
          Violation.new(
            type: :missing_layer,
            module: inspect(module),
            rule: "module does not match any configured layer"
          )
        ]

      coverage.forbid_multiple_matches and length(matches) > 1 ->
        [
          Violation.new(
            type: :multiple_layers,
            module: inspect(module),
            matched_layers: matches,
            rule: "module matches multiple configured layers"
          )
        ]

      true ->
        []
    end
  end

  defp project_modules(project) do
    project.nodes
    |> Enum.flat_map(fn
      {_id, %{type: :module_def, meta: %{name: module}}} -> [module]
      _ -> []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp dependency_violation_edge?(%{from: layer, to: layer}, _deps), do: false

  defp dependency_violation_edge?(edge, %{mode: :allowlist, allowed: allowed}) do
    not allowed_dependency?(edge, allowed)
  end

  defp dependency_violation_edge?(edge, deps) do
    Enum.any?(deps.forbidden, &forbidden_dependency_rule_matches?(&1, edge))
  end

  defp allowed_dependency?(edge, allowed) do
    edge.to in Keyword.get(allowed, edge.from, [])
  end

  defp forbidden_dependency_rule_matches?({from, to}, edge),
    do: edge.from == from and edge.to == to

  defp forbidden_dependency_rule_matches?({from, to, opts}, edge) do
    edge.from == from and edge.to == to and not dependency_excepted?(edge, opts)
  end

  defp forbidden_dependency_rule_matches?(_rule, _edge), do: false

  defp dependency_excepted?(edge, opts) do
    module_matches_any?(edge.caller, Keyword.get(opts, :except, [])) or
      Enum.any?(Keyword.get(opts, :except_edges, []), fn {caller_pattern, callee_pattern} ->
        module_matches_any?(edge.caller, [caller_pattern]) and
          module_matches_any?(edge.callee, [callee_pattern])
      end)
  end

  defp cycle_edge_witnesses(cycle, edges) do
    cycle_set = MapSet.new(cycle)

    cycle
    |> Enum.flat_map(fn from ->
      case Enum.find(edges, &(&1.from == from and MapSet.member?(cycle_set, &1.to))) do
        nil ->
          []

        edge ->
          [
            edge_violation_attrs(edge)
            |> Map.take([
              :caller_module,
              :caller_layer,
              :callee_module,
              :callee_layer,
              :file,
              :line,
              :call
            ])
          ]
      end
    end)
  end

  defp edge_violation_attrs(edge) do
    %{
      caller_module: inspect(edge.caller),
      caller_layer: edge.from,
      callee_module: inspect(edge.callee),
      callee_layer: edge.to,
      file: edge.node.source_span.file,
      line: edge.node.source_span.start_line,
      call: "#{inspect(edge.callee)}.#{edge.node.meta[:function]}/#{edge.node.meta[:arity]}"
    }
  end

  defp module_layer(module, layers) do
    layers
    |> matching_layers(module)
    |> List.first()
  end

  defp matching_layers(layers, module) when is_list(layers) do
    layers
    |> Enum.filter(fn {_layer, patterns} -> module_matches_any?(module, List.wrap(patterns)) end)
    |> Enum.map(fn {layer, _patterns} -> layer end)
  end
end
