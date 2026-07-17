defmodule Reach.Smell.Checks.ReturnShapeDivergence do
  @moduledoc "Detects incompatible terminal return contracts within one function."

  @behaviour Reach.Smell.Check

  alias Reach.Evidence
  alias Reach.Smell.Finding

  @raw_classes [:list, :map, :scalar, :struct]
  @contract_tag :ok

  @impl true
  def kinds, do: [:return_shape_divergence, :nested_return_tag]

  @impl true
  def run(project) do
    project
    |> Evidence.return_contracts()
    |> Enum.reject(& &1.impl)
    |> Enum.flat_map(&findings/1)
  end

  defp findings(fact) do
    nested_tag_findings(fact) ++ divergence_findings(fact)
  end

  defp nested_tag_findings(fact) do
    nested = Enum.filter(fact.outcomes, &(&1.nested_same_tag == @contract_tag))

    if nested == [] do
      []
    else
      tags = nested |> Enum.map(& &1.nested_same_tag) |> Enum.uniq() |> Enum.sort()
      locations = Enum.map_join(nested, ", ", &outcome_location/1)

      [
        Finding.new(
          kind: :nested_return_tag,
          message:
            "#{function_name(fact)} wraps #{Enum.map_join(tags, ", ", &inspect/1)} inside the same return tag at #{locations}; remove the duplicate wrapper and keep one contract layer",
          location: fact_location(fact),
          evidence: Enum.map(nested, &outcome_evidence/1),
          confidence: :high
        )
      ]
    end
  end

  defp divergence_findings(fact) do
    if divergent?(fact.outcomes) do
      [
        Finding.new(
          kind: :return_shape_divergence,
          message:
            "#{function_name(fact)} returns incompatible contracts #{shape_summary(fact.outcomes)}; choose one tagged return structure across every clause and branch",
          location: fact_location(fact),
          evidence: fact.outcomes |> known_outcomes() |> Enum.map(&outcome_evidence/1),
          confidence: :high
        )
      ]
    else
      []
    end
  end

  defp divergent?(outcomes) do
    if Enum.any?(outcomes, &(&1.class == :dynamic)) do
      false
    else
      known = known_outcomes(outcomes)

      length(known) >= 2 and
        (matching_bare_and_tagged?(known) or tagged_and_raw?(known) or
           inconsistent_tag_arity?(known))
    end
  end

  defp known_outcomes(outcomes), do: Enum.reject(outcomes, &(&1.class in [:dynamic, :no_return]))

  defp matching_bare_and_tagged?(outcomes) do
    tagged =
      outcomes
      |> Enum.filter(&(&1.class == :tagged))
      |> Enum.map(fn %{shape: {:tagged, tag, _arity}} -> tag end)
      |> MapSet.new()

    MapSet.member?(tagged, @contract_tag) and
      Enum.any?(outcomes, &(&1.shape == {:bare_atom, @contract_tag}))
  end

  defp tagged_and_raw?(outcomes) do
    tagged_with_contract_tag?(outcomes) and Enum.any?(outcomes, &(&1.class in @raw_classes))
  end

  defp inconsistent_tag_arity?(outcomes) do
    outcomes
    |> Enum.flat_map(fn
      %{shape: {:tagged, tag, arity}} -> [{tag, arity}]
      _outcome -> []
    end)
    |> Enum.filter(&(elem(&1, 0) == @contract_tag))
    |> Enum.map(&elem(&1, 1))
    |> Enum.uniq()
    |> length()
    |> Kernel.>(1)
  end

  defp tagged_with_contract_tag?(outcomes) do
    Enum.any?(outcomes, &match?(%{shape: {:tagged, @contract_tag, _arity}}, &1))
  end

  defp shape_summary(outcomes) do
    outcomes
    |> known_outcomes()
    |> Enum.uniq_by(& &1.shape)
    |> Enum.sort_by(&{&1.line || 0, &1.column || 0, &1.label})
    |> Enum.map_join(" vs ", &"#{&1.label} (#{outcome_location(&1)})")
  end

  defp outcome_evidence(outcome) do
    "#{outcome.label} at #{outcome_location(outcome)}"
  end

  defp outcome_location(%{line: nil}), do: "unknown line"
  defp outcome_location(%{line: line}), do: "line #{line}"

  defp fact_location(fact), do: "#{fact.file}:#{fact.line}"

  defp function_name(fact) do
    "#{inspect(fact.module)}.#{fact.function}/#{fact.arity}"
  end
end
