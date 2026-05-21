defmodule Reach.Check.Candidates do
  @moduledoc "Generates graph-backed refactoring candidates from cycles, effects, and pure regions."

  alias Reach.Analysis
  alias Reach.Check.{Architecture, Candidate, Changed}
  alias Reach.Config
  alias Reach.Evidence.MapContract
  alias Reach.IR.Helpers, as: IRHelpers
  alias Reach.Project.Query

  @note "Candidates are advisory. Reach reports graph/effect/architecture evidence; prove behavior preservation before editing."
  @non_contract_variable_names [:acc, :assigns, :cat, :count, :counts, :stats]

  def run(project, config, opts \\ []) do
    config = Config.normalize(config)
    top = Keyword.get(opts, :top, 40)

    candidates =
      (mixed_effect_candidates(project, config.candidates) ++
         extract_region_candidates(project, config.candidates) ++
         boundary_candidates(project, config) ++
         cycle_candidates(project, config.candidates) ++
         map_contract_candidates(project, config.candidates))
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(&candidate_rank/1)
      |> Enum.take(top)

    %{candidates: candidates, note: @note}
  end

  defp candidate_rank(candidate) do
    kind_rank = %{
      introduce_boundary: 0,
      isolate_effects: 1,
      introduce_struct_contract: 2,
      extract_pure_region: 3,
      break_cycle: 4
    }

    risk_rank = %{high: 0, medium: 1, low: 2}
    benefit_rank = %{high: 0, medium: 1, low: 2}

    {
      Map.get(kind_rank, candidate.kind, 9),
      Map.get(risk_rank, candidate.risk, 3),
      Map.get(benefit_rank, candidate.benefit, 3),
      candidate.id
    }
  end

  defp cycle_candidates(project, candidate_config) do
    deps = module_dependency_map(project)
    call_examples = module_call_examples(project, candidate_config)

    deps
    |> module_cycle_components()
    |> Enum.take(candidate_config.limits.per_kind)
    |> Enum.with_index(1)
    |> Enum.map(fn {cycle, index} ->
      Candidate.new(
        id: candidate_id("R3", index),
        kind: :break_cycle,
        target: Enum.join(cycle, " -> "),
        benefit: :high,
        risk: :medium,
        confidence: :low,
        actionability: :needs_project_policy,
        evidence: ["module_dependency_cycle"],
        proof: [
          "Confirm the cycle violates intended architecture before changing code.",
          "Review representative_calls to find the smallest boundary-breaking call.",
          "Prefer moving shared helpers downward over introducing a new abstraction."
        ],
        suggestion:
          "Move shared code to a lower-level module or route calls through an existing boundary.",
        modules: cycle,
        representative_calls:
          representative_component_calls(cycle, call_examples, candidate_config)
      )
    end)
  end

  defp module_dependency_map(project) do
    project
    |> module_call_edges()
    |> Enum.reduce(%{}, fn edge, acc ->
      Map.update(acc, edge.caller, MapSet.new([edge.callee]), &MapSet.put(&1, edge.callee))
    end)
    |> Map.new(fn {module, deps} -> {module, MapSet.to_list(deps)} end)
  end

  defp module_call_examples(project, candidate_config) do
    project
    |> module_call_edges()
    |> Enum.group_by(&{inspect(&1.caller), inspect(&1.callee)})
    |> Map.new(fn {key, edges} ->
      examples =
        edges
        |> Enum.take(candidate_config.limits.representative_calls_per_edge)
        |> Enum.map(&representative_call/1)

      {key, examples}
    end)
  end

  defp module_call_edges(project) do
    modules =
      for {_, node} <- project.nodes, node.type == :module_def, into: MapSet.new() do
        node.meta[:name]
      end

    module_by_file = Architecture.module_by_file(project)

    for {_, node} <- project.nodes,
        Architecture.remote_call?(node),
        caller = node.source_span && Map.get(module_by_file, node.source_span.file),
        callee = node.meta[:module],
        caller && callee && caller != callee && MapSet.member?(modules, callee) do
      %{caller: caller, callee: callee, node: node}
    end
  end

  defp representative_component_calls(cycle, call_examples, candidate_config) do
    cycle_modules = MapSet.new(cycle)

    call_examples
    |> Enum.flat_map(fn {{caller, callee}, examples} ->
      if MapSet.member?(cycle_modules, caller) and MapSet.member?(cycle_modules, callee) do
        examples
      else
        []
      end
    end)
    |> Enum.take(candidate_config.limits.representative_calls)
  end

  defp module_cycle_components(deps) do
    graph =
      Enum.reduce(deps, Graph.new(type: :directed), fn {module, module_deps}, graph ->
        Enum.reduce(module_deps, Graph.add_vertex(graph, module), fn dep, graph ->
          Graph.add_edge(graph, module, dep)
        end)
      end)

    Reach.GraphAlgorithms.cycle_components(graph, &canonical_module_cycle/1)
  end

  defp representative_call(%{caller: caller, callee: callee, node: node}) do
    callee_name = inspect(callee)

    %{
      caller_module: inspect(caller),
      callee_module: callee_name,
      file: node.source_span && node.source_span.file,
      line: node.source_span && node.source_span.start_line,
      call: "#{callee_name}.#{node.meta[:function]}/#{node.meta[:arity]}"
    }
  end

  defp canonical_module_cycle(cycle) do
    cycle
    |> Enum.map(&inspect/1)
    |> Enum.sort()
  end

  defp mixed_effect_candidates(project, candidate_config) do
    for({_, node} <- project.nodes, node.type == :function_def and node.source_span, do: node)
    |> Enum.reject(&Analysis.expected_effect_boundary?/1)
    |> Enum.map(fn func -> {func, Architecture.concrete_effects(func)} end)
    |> Enum.filter(fn {_func, effects} ->
      length(effects) >= candidate_config.thresholds.mixed_effect_count
    end)
    |> Enum.sort_by(fn {func, effects} ->
      {-length(effects), func.source_span.file, func.source_span.start_line}
    end)
    |> Enum.take(candidate_config.limits.per_kind)
    |> Enum.with_index(1)
    |> Enum.map(fn {{func, effects}, index} ->
      id = {func.meta[:module], func.meta[:name], func.meta[:arity]}

      Candidate.new(
        id: candidate_id("R2", index),
        kind: :isolate_effects,
        target: IRHelpers.func_id_to_string(id),
        file: func.source_span.file,
        line: func.source_span.start_line,
        benefit: :medium,
        risk: :medium,
        confidence: :medium,
        actionability: :review_effect_order,
        evidence: ["mixed_effects"],
        effects: Enum.map(effects, &to_string/1),
        proof: [
          "Preserve side-effect order exactly.",
          "Extract only pure decision/preparation code first.",
          "Run tests covering both success and error paths."
        ],
        suggestion:
          "Split pure decision logic from side-effect execution while preserving effect order."
      )
    end)
  end

  defp extract_region_candidates(project, candidate_config) do
    for({_, node} <- project.nodes, node.type == :function_def and node.source_span, do: node)
    |> Enum.map(fn func ->
      {func, Changed.branch_count(func), Query.callers(project, function_id(func), 1)}
    end)
    |> Enum.filter(fn {_func, branches, callers} ->
      branches >= candidate_config.thresholds.branchy_function_branches and callers != []
    end)
    |> Enum.reject(fn {func, _branches, _callers} ->
      Analysis.expected_effect_boundary?(func) and
        Changed.branch_count(func) < candidate_config.thresholds.branchy_function_branches * 2
    end)
    |> Enum.sort_by(fn {func, branches, callers} ->
      {-branches * max(length(callers), 1), func.source_span.file, func.source_span.start_line}
    end)
    |> Enum.take(candidate_config.limits.per_kind)
    |> Enum.with_index(1)
    |> Enum.map(fn {{func, branches, callers}, index} ->
      Candidate.new(
        id: candidate_id("R1", index),
        kind: :extract_pure_region,
        target: IRHelpers.func_id_to_string(function_id(func)),
        file: func.source_span.file,
        line: func.source_span.start_line,
        benefit: :medium,
        risk:
          if(length(callers) >= candidate_config.thresholds.high_risk_direct_callers,
            do: :high,
            else: :medium
          ),
        confidence: :medium,
        actionability: :needs_region_proof,
        evidence: ["branchy_function", "caller_impact"],
        branches: branches,
        direct_caller_count: length(callers),
        proof: [
          "Identify a single-entry/single-exit region before editing.",
          "Verify extracted region has explicit inputs and one clear output.",
          "Add or run fixture tests around behavior and source spans."
        ],
        suggestion:
          "Look for a single-entry/single-exit pure branch region before extracting. Do not extract by size alone."
      )
    end)
  end

  defp function_id(func), do: {func.meta[:module], func.meta[:name], func.meta[:arity]}

  defp map_contract_candidates(project, candidate_config) do
    project
    |> project_source_files()
    |> Enum.flat_map(&map_contracts_in_file/1)
    |> Enum.group_by(& &1.keys)
    |> Enum.flat_map(&map_contract_candidate_group/1)
    |> Enum.sort_by(fn {keys, contracts} -> {-length(contracts), length(keys), inspect(keys)} end)
    |> Enum.take(candidate_config.limits.per_kind)
    |> Enum.with_index(1)
    |> Enum.map(fn {{keys, contracts}, index} ->
      first = List.first(contracts)
      sources = contracts |> Enum.map(& &1.source) |> Enum.uniq()

      Candidate.new(
        id: candidate_id("R6", index),
        kind: :introduce_struct_contract,
        target: "map shape #{inspect(keys)}",
        file: first.file,
        line: first.location.line,
        benefit: :medium,
        risk: :low,
        confidence: map_contract_confidence(contracts),
        actionability: :review_domain_contract,
        evidence: map_contract_evidence(contracts, sources, candidate_config),
        keys: Enum.map(keys, &to_string/1),
        occurrences: length(contracts),
        sources: Enum.map(sources, &to_string/1),
        proof: [
          "Confirm this repeated map shape represents domain data, not an external JSON/API boundary.",
          "Prefer a struct when the shape is internal and stable across functions.",
          "Keep plain maps for dynamic, user-provided, or third-party payloads."
        ],
        suggestion:
          "Consider replacing this repeated implicit map contract with a struct or explicit boundary type."
      )
    end)
  end

  defp map_contract_candidate_group({keys, contracts}) do
    cond do
      length(contracts) >= 2 and not all_non_contract_variables?(contracts) ->
        [{keys, contracts}]

      Enum.any?(contracts, &return_contract_candidate?/1) ->
        [{keys, contracts}]

      true ->
        []
    end
  end

  defp return_contract_candidate?(contract) do
    contract.source == :return and contract.confidence == :high and length(contract.keys) >= 4 and
      contract.variable not in @non_contract_variable_names
  end

  defp all_non_contract_variables?(contracts) do
    Enum.all?(contracts, &(&1.variable in @non_contract_variable_names))
  end

  defp project_source_files(project) do
    project.nodes
    |> Map.values()
    |> Enum.flat_map(fn node ->
      case node.source_span do
        %{file: file} when is_binary(file) -> [file]
        _span -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.reject(&dependency_source_file?/1)
    |> Enum.sort()
  end

  defp dependency_source_file?(file) do
    String.contains?(file, "/deps/") or String.contains?(file, "/_build/")
  end

  defp map_contracts_in_file(file) do
    with {:ok, source} <- File.read(file),
         {:ok, ast} <- Code.string_to_quoted(source, emit_warnings: false) do
      ast
      |> MapContract.collect_ast()
      |> Enum.map(&Map.put(&1, :file, file))
    else
      _error -> []
    end
  end

  defp map_contract_confidence(contracts) do
    cond do
      Enum.any?(contracts, &(&1.confidence == :high)) -> :high
      Enum.any?(contracts, &(&1.source == :return)) -> :medium
      true -> :low
    end
  end

  defp map_contract_evidence(contracts, sources, candidate_config) do
    source_labels = Enum.map(sources, &"#{&1}_evidence")

    examples =
      contracts
      |> Enum.take(candidate_config.limits.representative_calls)
      |> Enum.map(fn contract ->
        producer = if contract.producer, do: " from #{inspect(contract.producer)}", else: ""
        "#{contract.file}:#{contract.location.line} #{contract.variable}#{producer}"
      end)

    source_labels ++ examples
  end

  defp boundary_candidates(_project, %{layers: []}), do: []

  defp boundary_candidates(project, config) do
    layer_graph = Architecture.layer_graph(project, config)

    Architecture.dependency_violations(project, config, layer_graph)
    |> Enum.take(config.candidates.limits.per_kind)
    |> Enum.with_index(1)
    |> Enum.map(fn {violation, index} ->
      Candidate.new(
        id: candidate_id("R5", index),
        kind: :introduce_boundary,
        target: "#{violation.caller_layer} -> #{violation.callee_layer}",
        file: violation.file,
        line: violation.line,
        benefit: :high,
        risk: :medium,
        confidence: :high,
        actionability: :policy_violation,
        evidence: ["architecture_policy_violation", "forbidden_dependency"],
        call: violation.call,
        proof: [
          "Verify the .reach.exs policy matches the intended architecture.",
          "Route through an existing boundary when possible.",
          "Avoid making internal modules public just to silence the violation."
        ],
        suggestion:
          "Route this call through an allowed boundary or move the helper to an allowed lower layer."
      )
    end)
  end

  defp candidate_id(prefix, index),
    do: "#{prefix}-#{String.pad_leading(to_string(index), 3, "0")}"
end
