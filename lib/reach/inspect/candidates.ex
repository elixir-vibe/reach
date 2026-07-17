defmodule Reach.Inspect.Candidates do
  @moduledoc """
  Finds advisory graph-backed refactoring candidates for one target function.
  """

  alias Reach.Analysis
  alias Reach.Check.{BoundaryContractCandidates, Candidate}
  alias Reach.Config
  alias Reach.Effects
  alias Reach.IR
  alias Reach.Project.Query

  def find(project, mfa, func, candidate_config \\ %Config.Candidates{}) do
    candidate_config = Config.normalize(%Config{candidates: candidate_config}).candidates

    non_pure_effects =
      function_effect_atoms(func, project.plugins) -- [:pure, :unknown, :exception]

    callers = Query.callers(project, mfa, 1)
    branch_count = branch_count(func)

    local_candidates =
      []
      |> maybe_candidate(
        isolate_effects_candidate(func, non_pure_effects, candidate_config, project.plugins)
      )
      |> maybe_candidate(extract_region_candidate(func, branch_count, callers, candidate_config))

    local_candidates ++ boundary_contract_candidates(project, mfa, candidate_config)
  end

  defp isolate_effects_candidate(func, effects, candidate_config, plugins) do
    cond do
      length(effects) < candidate_config.thresholds.mixed_effect_count ->
        nil

      Analysis.expected_effect_boundary?(func, plugins) ->
        nil

      true ->
        Candidate.new(
          id: "R2-001",
          kind: :isolate_effects,
          file: func.source_span && func.source_span.file,
          line: func.source_span && func.source_span.start_line,
          benefit: :medium,
          risk: :medium,
          confidence: :medium,
          actionability: :review_effect_order,
          evidence: ["mixed_effects"],
          effects: effects,
          proof: [
            "Preserve side-effect order exactly.",
            "Extract only pure decision/preparation code first.",
            "Run tests covering both success and error paths."
          ],
          suggestion:
            "Split pure decision logic from side-effect execution while preserving effect order."
        )
    end
  end

  defp extract_region_candidate(func, branch_count, callers, candidate_config) do
    if branch_count < candidate_config.thresholds.branchy_function_branches do
      nil
    else
      do_extract_region_candidate(func, branch_count, callers, candidate_config)
    end
  end

  defp do_extract_region_candidate(func, branch_count, callers, candidate_config) do
    Candidate.new(
      id: "R1-001",
      kind: :extract_pure_region,
      file: func.source_span && func.source_span.file,
      line: func.source_span && func.source_span.start_line,
      benefit: :medium,
      risk:
        if(length(callers) >= candidate_config.thresholds.high_risk_direct_callers,
          do: :high,
          else: :medium
        ),
      confidence: :medium,
      actionability: :needs_region_proof,
      evidence: ["branchy_function", "caller_impact"],
      branches: branch_count,
      direct_caller_count: length(callers),
      proof: [
        "Identify a single-entry/single-exit region before editing.",
        "Verify extracted region has explicit inputs and one clear output.",
        "Add or run fixture tests around behavior and source spans."
      ],
      suggestion:
        "Look for a single-entry/single-exit pure branch region before extracting. Do not extract by size alone."
    )
  end

  defp boundary_contract_candidates(project, mfa, candidate_config) do
    target = mfa_to_string(mfa)

    project
    |> BoundaryContractCandidates.build(candidate_config)
    |> Enum.filter(&(target in &1.blast_radius))
  end

  defp mfa_to_string({module, function, arity}), do: "#{inspect(module)}.#{function}/#{arity}"

  defp maybe_candidate(candidates, nil), do: candidates
  defp maybe_candidate(candidates, candidate), do: candidates ++ [candidate]

  defp branch_count(func) do
    func
    |> IR.all_nodes()
    |> Enum.count(
      &(&1.type in [:case, :receive, :try] or
          (&1.type == :binary_op and &1.meta[:operator] in [:and, :or, :&&, :||]))
    )
  end

  defp function_effect_atoms(func, plugins) do
    func
    |> IR.all_nodes()
    |> Enum.map(&Effects.classify(&1, plugins))
    |> Enum.uniq()
    |> Enum.sort()
  end
end
