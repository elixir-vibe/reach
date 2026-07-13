defmodule Reach.Map.EffectRow do
  @moduledoc "Struct for a per-function effect classification row."
  @derive JSON.Encoder
  defstruct [:effect, :count, :ratio]

  @type t :: %__MODULE__{
          effect: Reach.Effects.effect(),
          count: non_neg_integer(),
          ratio: float()
        }
  def new(attrs), do: struct!(__MODULE__, attrs)
end
