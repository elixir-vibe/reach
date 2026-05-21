defmodule Reach.Check.Candidate do
  @moduledoc "Struct for an advisory refactoring candidate with confidence and proof."

  @derive Jason.Encoder
  defstruct [
    :id,
    :kind,
    :target,
    :file,
    :line,
    :benefit,
    :risk,
    :confidence,
    :actionability,
    :evidence,
    :effects,
    :proof,
    :suggestion,
    :modules,
    :representative_calls,
    :call,
    :branches,
    :direct_caller_count,
    :keys,
    :occurrences,
    :sources
  ]

  def new(attrs) when is_list(attrs) or is_map(attrs), do: struct!(__MODULE__, attrs)
end
