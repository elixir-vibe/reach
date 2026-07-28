defmodule Reach.Map.EffectSourceRow do
  @moduledoc "Classification provenance totals for a project effect summary."

  @derive JSON.Encoder
  defstruct [:source, :classifier, :confidence, :count, :ratio]

  @type t :: %__MODULE__{
          source: Reach.Effects.Classification.source(),
          classifier: String.t() | nil,
          confidence: Reach.Effects.Classification.confidence(),
          count: non_neg_integer(),
          ratio: float()
        }

  def new(attrs), do: struct!(__MODULE__, attrs)
end
