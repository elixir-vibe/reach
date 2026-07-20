defmodule Reach.Check.BoundaryContractCandidates do
  @moduledoc "Builds advisory normalization candidates from fixed external-data boundary evidence."

  alias Reach.Check.Candidate
  alias Reach.Evidence.{ExternalDataBoundary, Impact}
  alias Reach.IR.Helpers, as: IRHelpers
  alias Reach.Project.Query

  @field_name ~r/^[a-z_][a-zA-Z0-9_]*[?!]?$/

  @spec build(Reach.Project.t(), Reach.Config.Candidates.t()) :: [Candidate.t()]
  def build(project, candidate_config) do
    project
    |> ExternalDataBoundary.collect_project()
    |> Enum.filter(&ExternalDataBoundary.fixed_contract?/1)
    |> Enum.take(candidate_config.limits.per_kind)
    |> Enum.with_index(1)
    |> Enum.map(fn {fact, index} -> candidate(fact, index, project, candidate_config) end)
  end

  defp candidate(fact, index, project, candidate_config) do
    blast_radius = blast_radius(fact, project, candidate_config)
    target = boundary_target(fact)

    Candidate.new(
      id: "R10-#{String.pad_leading(to_string(index), 3, "0")}",
      kind: :introduce_boundary_contract,
      target: target,
      file: fact.file,
      line: fact.line,
      benefit: :high,
      risk: :medium,
      confidence: :high,
      actionability: :normalize_boundary_contract,
      evidence: evidence(fact, blast_radius),
      keys: fact.consumer_keys,
      occurrences: length(fact.consumer_functions),
      sources: [fact.source],
      boundary: fact.boundary,
      decoder: fact.source,
      canonical_site: %{
        target: target,
        file: fact.file,
        line: fact.line,
        reason: :normalization_boundary
      },
      draft_contract: draft_contract(fact.consumer_keys),
      blast_radius: blast_radius,
      proof: [
        "Add fixture coverage for decoder success, missing keys, and malformed values before changing the stored shape.",
        "Normalize immediately before #{fact.boundary}; do not move string-key fallbacks to another consumer.",
        "Replace every listed literal-key consumer with the explicit contract and preserve boundary read/write behavior.",
        "Run the listed blast-radius functions and their callers through focused tests."
      ],
      suggestion:
        "Normalize #{fact.source} output into a dedicated struct or validated schema at #{target}; require #{Enum.join(fact.consumer_keys, ", ")} explicitly instead of defaulting downstream."
    )
  end

  defp boundary_target(%{boundary_function: nil, boundary: boundary}), do: boundary

  defp boundary_target(fact) do
    "#{IRHelpers.func_id_to_string(fact.boundary_function)} at #{fact.boundary}"
  end

  defp evidence(fact, blast_radius) do
    consumers = Enum.map(fact.consumer_functions, &IRHelpers.func_id_to_string/1)

    [
      "decoder #{fact.source} line=#{fact.source_line}",
      "boundary #{fact.boundary}",
      "fixed_keys #{Enum.join(fact.consumer_keys, ",")}",
      "consumer_functions #{Enum.join(consumers, ",")}",
      "blast_radius #{length(blast_radius)} functions"
    ]
  end

  defp draft_contract(keys) do
    if Enum.all?(keys, &Regex.match?(@field_name, &1)) do
      fields = Enum.map_join(keys, ", ", &":#{&1}")
      "@enforce_keys [#{fields}]\ndefstruct [#{fields}]"
    else
      "validation schema with required external keys #{inspect(keys)}"
    end
  end

  defp blast_radius(fact, project, candidate_config) do
    targets =
      [fact.boundary_function | fact.consumer_functions]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    targets
    |> Enum.flat_map(&impact_functions(&1, project, candidate_config))
    |> Enum.uniq()
    |> Enum.take(candidate_config.limits.boundary_contract_blast_radius)
    |> Enum.map(&IRHelpers.func_id_to_string/1)
  end

  defp impact_functions(target, project, candidate_config) do
    module = elem(target, 0)

    callers =
      project
      |> Impact.callers(target, candidate_config.limits.boundary_contract_impact_depth)
      |> Enum.map(&normalize_module(&1, project, module))

    [target | callers]
  end

  defp normalize_module({nil, function, arity} = mfa, project, fallback_module) do
    functions = Map.get(Query.function_index(project).by_name_arity, {function, arity}, [])

    case Enum.map(functions, & &1.meta[:module]) |> Enum.uniq() do
      [module] ->
        {module, function, arity}

      modules ->
        if fallback_module in modules, do: {fallback_module, function, arity}, else: mfa
    end
  end

  defp normalize_module(mfa, _project, _fallback_module), do: mfa
end
