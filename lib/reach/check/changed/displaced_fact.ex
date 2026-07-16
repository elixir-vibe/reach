defmodule Reach.Check.Changed.DisplacedFact do
  @moduledoc "A persistent evidence fact that moved instead of being resolved."

  @derive JSON.Encoder
  @enforce_keys [:family, :fingerprint, :old_locations, :new_locations, :message]
  defstruct [
    :family,
    :fingerprint,
    :key,
    :old_locations,
    :new_locations,
    :message,
    :suggestion,
    :occurrences_before,
    :occurrences_after,
    status: :displaced,
    confidence: :high
  ]

  @type family :: :dual_key_contract | :default_drift | :exact_clone

  @type t :: %__MODULE__{
          family: family(),
          fingerprint: String.t(),
          key: String.t() | nil,
          old_locations: [map()],
          new_locations: [map()],
          message: String.t(),
          suggestion: String.t(),
          occurrences_before: pos_integer(),
          occurrences_after: pos_integer(),
          status: :displaced,
          confidence: :high | :medium
        }

  def new(attrs), do: struct!(__MODULE__, attrs)
end
