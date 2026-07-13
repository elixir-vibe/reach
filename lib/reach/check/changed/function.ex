defmodule Reach.Check.Changed.Function do
  @moduledoc "Struct for a changed function with risk metadata."

  @derive JSON.Encoder
  defstruct [
    :id,
    :file,
    :line,
    :risk,
    :risk_reasons,
    :public_api,
    :effects,
    :branch_count,
    :direct_callers,
    :direct_caller_count,
    :transitive_caller_count,
    clone_siblings: []
  ]

  @type t :: %__MODULE__{
          risk: :high | :medium | :low,
          effects: [Reach.Effects.effect()],
          clone_siblings: [map()]
        }

  def new(attrs), do: struct!(__MODULE__, attrs)
end
