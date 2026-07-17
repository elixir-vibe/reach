defmodule Reach.Smell.Checks.ParameterShapeEntropy do
  @moduledoc "Detects domain parameters receiving divergent fixed map shapes."

  @behaviour Reach.Smell.Check

  alias Reach.Evidence.ParameterShape
  alias Reach.Smell.{Finding, ParameterShapePolicy}

  @impl true
  def kinds, do: [:parameter_shape_entropy]

  @impl true
  def run(project), do: run(project, %{})

  def run(project, config) do
    config = entropy_config(config)

    project
    |> ParameterShape.collect_project()
    |> Enum.filter(&ParameterShapePolicy.eligible?(&1, config))
    |> Enum.map(&finding(&1, config))
  end

  defp entropy_config(%{smells: smells}), do: entropy_config(smells)

  defp entropy_config(%{parameter_shape_entropy: config}) when not is_nil(config),
    do: entropy_config(config)

  defp entropy_config(config) do
    %{
      min_callers: Map.get(config, :min_callers, 2),
      min_variants: Map.get(config, :min_variants, 2),
      min_union_keys: Map.get(config, :min_union_keys, 3),
      min_consumed_keys: Map.get(config, :min_consumed_keys, 2),
      min_entropy: Map.get(config, :min_entropy, 0.5),
      evidence_limit: Map.get(config, :evidence_limit, 8)
    }
  end

  defp finding(fact, config) do
    target = format_target(fact.target)
    variants = Enum.map(fact.variants, &inspect/1)
    locations = Enum.map(fact.occurrences, &"#{&1.file}:#{&1.line}")

    Finding.new(
      kind: :parameter_shape_entropy,
      message:
        "#{target} parameter #{fact.parameter} receives #{length(fact.variants)} divergent map shapes from #{length(fact.callers)} callers; split the contract or normalize it before the function boundary",
      location: "#{fact.file}:#{fact.line}",
      evidence:
        [
          "core_keys=#{inspect(fact.core_keys)}",
          "optional_keys=#{inspect(fact.optional_keys)}",
          "consumed_keys=#{inspect(fact.consumed_keys)}",
          "strict_consumed_keys=#{inspect(fact.strict_consumed_keys)}",
          "variants=#{Enum.join(variants, " | ")}",
          recommendation(fact)
        ] ++ Enum.take(locations, config.evidence_limit),
      keys: Enum.map(fact.union_keys, &to_string/1),
      occurrences: length(fact.occurrences),
      confidence: :medium
    )
  end

  defp recommendation(%{core_keys: []}) do
    "suggestion=split the shape families into named functions or add an explicit literal variant tag"
  end

  defp recommendation(fact) do
    "suggestion=introduce a struct with required core keys #{inspect(fact.core_keys)} and explicit optional fields"
  end

  defp format_target({module, function, arity}), do: "#{inspect(module)}.#{function}/#{arity}"
end
