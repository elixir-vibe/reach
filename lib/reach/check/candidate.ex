defmodule Reach.Check.Candidate do
  @moduledoc "Struct for an advisory refactoring candidate with confidence and proof."

  @derive JSON.Encoder
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

  @type t :: %__MODULE__{
          risk: :high | :medium | :low,
          confidence: :high | :medium | :low,
          effects: [Reach.Effects.effect()] | nil
        }

  def new(attrs) when is_list(attrs) or is_map(attrs), do: struct!(__MODULE__, attrs)
end
