defmodule Reach.Smell.Checks.SameEntityRepresentation do
  @moduledoc "Detects bare maps that duplicate an existing struct's entity shape."

  @behaviour Reach.Smell.Check

  alias Reach.Evidence.RepresentationOverlap
  alias Reach.Smell.Finding

  @impl true
  def kinds, do: [:same_entity_representation]

  @impl true
  def run(project), do: run(project, %{})

  def run(project, config) do
    config = overlap_config(config)

    project
    |> RepresentationOverlap.collect_project(
      min_shared_keys: config.min_shared_keys,
      min_similarity: config.min_similarity
    )
    |> Enum.filter(&promotable?(&1, config))
    |> Enum.group_by(&{&1.struct.module, &1.map.module})
    |> Enum.map(&finding(&1, config))
  end

  defp overlap_config(%{smells: smells}), do: overlap_config(smells)

  defp overlap_config(%{representation_overlap: config}) when not is_nil(config),
    do: overlap_config(config)

  defp overlap_config(config) do
    %{
      min_shared_keys: Map.get(config, :min_shared_keys, 3),
      min_similarity: Map.get(config, :min_similarity, 0.8),
      require_name_match: Map.get(config, :require_name_match, true),
      evidence_limit: Map.get(config, :evidence_limit, 8)
    }
  end

  defp promotable?(fact, config) do
    name_matches? = not config.require_name_match or fact.name_match?

    name_matches? and fact.map.role == :domain and
      fact.map.normalized_into != fact.struct.module and
      fact.struct.map_conversion_functions == [] and
      not direct_entity_projection?(fact)
  end

  defp direct_entity_projection?(fact) do
    entity = entity_name(fact.struct.module)

    fact.map.projection? and
      Enum.any?(fact.map.projection_sources, &(singular(to_string(&1)) == singular(entity)))
  end

  defp finding({{struct_module, map_module}, facts}, config) do
    facts = Enum.sort_by(facts, &{&1.map.file, &1.map.line || 0})
    first = List.first(facts)
    shared = facts |> Enum.flat_map(& &1.shared_keys) |> Enum.uniq() |> Enum.sort()
    locations = Enum.map(facts, &"#{&1.map.file}:#{&1.map.line}")

    Finding.new(
      kind: :same_entity_representation,
      message:
        "#{inspect(map_module)} constructs bare maps matching existing #{inspect(struct_module)}; use the canonical struct or an explicit conversion boundary",
      location: List.first(locations),
      evidence:
        ["#{first.struct.file}:#{first.struct.line} #{inspect(struct_module)} defstruct"] ++
          Enum.take(locations, config.evidence_limit),
      confidence: :medium,
      keys: Enum.map(shared, &to_string/1),
      modules: [inspect(struct_module), inspect(map_module)],
      occurrences: length(facts)
    )
  end

  defp entity_name(module), do: module |> Module.split() |> List.last() |> Macro.underscore()

  defp singular(name) do
    cond do
      String.ends_with?(name, "ies") -> String.replace_suffix(name, "ies", "y")
      String.ends_with?(name, "s") -> String.trim_trailing(name, "s")
      true -> name
    end
  end
end
