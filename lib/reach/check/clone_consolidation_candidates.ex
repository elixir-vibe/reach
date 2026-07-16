defmodule Reach.Check.CloneConsolidationCandidates do
  @moduledoc "Selects deterministic canonical functions for exact project clone families."

  alias Reach.Check.Candidate
  alias Reach.Evidence.Facade
  alias Reach.Map.Analysis, as: MapAnalysis
  alias Reach.Project.Query

  @spec build([Reach.Evidence.CloneAnalysis.Clone.t()], Reach.Project.t(), Reach.Config.t()) ::
          [Candidate.t()]
  def build([], _project, _config), do: []

  def build(clones, project, config) do
    build(clones, project, config, Facade.collect_project(project))
  end

  @doc false
  @spec build(
          [Reach.Evidence.CloneAnalysis.Clone.t()],
          Reach.Project.t(),
          Reach.Config.t(),
          [Facade.Module.t()]
        ) :: [Candidate.t()]
  def build([], _project, _config, _facade_modules), do: []

  def build(clones, project, config, facade_modules) do
    coupling = Map.new(MapAnalysis.module_coupling(project), &{&1.name, &1})
    excluded_modules = excluded_modules(facade_modules)
    minimum_fragments = config.candidates.thresholds.clone_consolidation_min_fragments

    clones
    |> Enum.filter(&(&1.type == :type_i))
    |> Enum.map(&clone_fragments(&1, excluded_modules))
    |> Enum.filter(&(length(&1) >= minimum_fragments))
    |> Enum.uniq_by(&clone_signature/1)
    |> Enum.map(&rank_clone(&1, project, coupling))
    |> Enum.sort_by(fn ranked -> fragment_location_key(ranked.canonical.fragment) end)
    |> Enum.take(config.candidates.limits.per_kind)
    |> Enum.with_index(1)
    |> Enum.map(fn {ranked, index} -> candidate(ranked, index) end)
  end

  defp clone_fragments(clone, excluded_modules) do
    clone.fragments
    |> Enum.filter(&project_function_fragment?/1)
    |> Enum.reject(&MapSet.member?(excluded_modules, inspect(&1.module)))
    |> Enum.sort_by(&fragment_location_key/1)
    |> Enum.uniq_by(&{&1.module, &1.function, &1.arity})
  end

  defp project_function_fragment?(fragment) do
    fragment.origin in [nil, :project] and fragment.whole_function == true and
      is_atom(fragment.module) and is_atom(fragment.function) and is_integer(fragment.arity) and
      is_binary(fragment.file) and is_integer(fragment.line)
  end

  defp excluded_modules(facade_modules) do
    facade_modules
    |> Enum.filter(&Enum.any?(&1.boundary_markers, fn marker -> marker in [:behaviour, :use] end))
    |> MapSet.new(& &1.module)
  end

  defp clone_signature(fragments) do
    Enum.map(fragments, &{&1.module, &1.function, &1.arity})
  end

  defp rank_clone(fragments, project, coupling) do
    ranked = Enum.map(fragments, &rank_fragment(&1, project, coupling))
    canonical = Enum.min_by(ranked, & &1.score)
    siblings = Enum.reject(ranked, &(&1.fragment == canonical.fragment))
    %{canonical: canonical, siblings: siblings}
  end

  defp rank_fragment(fragment, project, coupling) do
    module_coupling = Map.get(coupling, inspect(fragment.module))
    instability = module_coupling && module_coupling.instability
    efferent = module_coupling && module_coupling.efferent
    callers = Query.callers(project, fragment_mfa(fragment), 1) |> length()
    completeness = completeness(fragment)

    %{
      fragment: fragment,
      instability: instability || 1.0,
      efferent: efferent || 0,
      callers: callers,
      completeness: completeness,
      score: {
        instability || 1.0,
        efferent || 0,
        -completeness,
        -callers,
        fragment_location_key(fragment)
      }
    }
  end

  defp completeness(fragment) do
    length(fragment.effects || []) +
      length(fragment.effect_sequence || []) +
      length(fragment.validation_calls || []) +
      length(fragment.return_shapes || [])
  end

  defp candidate(ranked, index) do
    canonical = ranked.canonical
    fragment = canonical.fragment

    Candidate.new(
      id: "R9-#{String.pad_leading(to_string(index), 3, "0")}",
      kind: :consolidate_clone,
      target: function_name(fragment),
      file: fragment.file,
      line: fragment.line,
      benefit: :medium,
      risk: :medium,
      confidence: :high,
      actionability: :needs_behavior_equivalence,
      evidence: [
        "exact_type_i_clone",
        "canonical_score instability=#{canonical.instability} efferent=#{canonical.efferent} completeness=#{canonical.completeness} callers=#{canonical.callers}"
      ],
      occurrences: length(ranked.siblings) + 1,
      sources: [
        fragment_location(fragment) | Enum.map(ranked.siblings, &fragment_location(&1.fragment))
      ],
      clone_siblings: Enum.map(ranked.siblings, &clone_sibling/1),
      proof: [
        "Verify every clone has the same observable behavior, return contract, and error handling.",
        "Preserve public APIs with thin delegates only when callers require compatibility.",
        "Move callers incrementally and run tests covering every former implementation."
      ],
      suggestion:
        "Consolidate equivalent implementations into #{function_name(fragment)}; keep adapters only where they preserve an intentional boundary."
    )
  end

  defp clone_sibling(ranked) do
    fragment = ranked.fragment
    %{id: function_name(fragment), file: fragment.file, line: fragment.line}
  end

  defp fragment_mfa(fragment), do: {fragment.module, fragment.function, fragment.arity}

  defp function_name(fragment),
    do: "#{inspect(fragment.module)}.#{fragment.function}/#{fragment.arity}"

  defp fragment_location(fragment), do: "#{fragment.file}:#{fragment.line}"
  defp fragment_location_key(fragment), do: {fragment.file || "", fragment.line || 0}
end
