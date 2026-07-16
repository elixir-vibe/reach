defmodule Reach.Check.DependencyBypassCandidates do
  @moduledoc "Promotes exact project-to-dependency clone evidence into advisory refactoring candidates."

  alias Reach.Check.Candidate

  @spec build([Reach.Evidence.Fact.t()], Reach.Config.Candidates.t()) :: [Candidate.t()]
  def build(facts, candidate_config) do
    facts
    |> Enum.filter(&high_confidence_dependency_clone?/1)
    |> Enum.sort_by(&fact_sort_key/1)
    |> Enum.take(candidate_config.limits.per_kind)
    |> Enum.with_index(1)
    |> Enum.map(fn {fact, index} -> candidate(fact, index) end)
  end

  defp high_confidence_dependency_clone?(fact) do
    fact.confidence == :high and
      get_in(fact.data, [:category]) == :capability_bypass and
      get_in(fact.data, [:origin]) == :dependency_clone
  end

  defp fact_sort_key(fact) do
    fragment = fact.data.project_fragment
    {fragment.file || "", fragment.line || 0, fact.data.provider}
  end

  defp candidate(fact, index) do
    fragment = fact.data.project_fragment
    dependency = fact.data.provider

    Candidate.new(
      id: "R7-#{String.pad_leading(to_string(index), 3, "0")}",
      kind: :reuse_dependency,
      target: target(fragment, dependency),
      file: fragment.file,
      line: fragment.line,
      benefit: :medium,
      risk: :medium,
      confidence: :high,
      actionability: :needs_dependency_api_review,
      evidence: [
        "exact_project_dependency_clone",
        "dependency=#{dependency}",
        "dependency_source=#{fact.replacement}"
      ],
      proof: [
        "Confirm the dependency fragment belongs to a supported public API before replacing code.",
        "Compare edge cases and return contracts between the project and dependency implementations.",
        "Keep the local implementation when it intentionally diverges, and document that boundary."
      ],
      suggestion:
        "Reuse the #{dependency} implementation through its public API when behavior is equivalent; do not copy dependency internals."
    )
  end

  defp target(fragment, dependency) do
    project_target =
      if fragment.module && fragment.function do
        "#{inspect(fragment.module)}.#{fragment.function}/#{fragment.arity}"
      else
        "#{fragment.file}:#{fragment.line}"
      end

    "#{project_target} duplicates #{dependency} source"
  end
end
