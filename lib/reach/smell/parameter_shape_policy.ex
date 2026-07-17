defmodule Reach.Smell.ParameterShapePolicy do
  @moduledoc "Shared promotion policy for absolute and changed parameter-shape entropy."

  @spec eligible?(Reach.Evidence.ParameterShape.Fact.t(), map()) :: boolean()
  def eligible?(fact, config) do
    fact.role == :domain and not intentional_shape_dispatch?(fact) and
      length(fact.callers) >= config.min_callers and
      length(fact.variants) >= config.min_variants and
      length(fact.union_keys) >= config.min_union_keys and
      length(fact.consumed_keys) >= config.min_consumed_keys and
      consumes_variant_key?(fact) and fact.entropy >= config.min_entropy
  end

  defp intentional_shape_dispatch?(fact) do
    fact.intentional_dispatch? or fact.companion_dispatch? or fact.tagged_variants?
  end

  defp consumes_variant_key?(fact) do
    strict = MapSet.new(fact.strict_consumed_keys)
    optional = MapSet.new(fact.optional_keys)
    not MapSet.disjoint?(strict, optional)
  end
end
