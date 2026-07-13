defmodule Reach.Map.Boundary do
  @moduledoc "Struct for functions with multiple distinct side-effect kinds."
  @derive JSON.Encoder
  defstruct [:module, :function, :display_function, :file, :line, :effects, :calls]

  @type t :: %__MODULE__{effects: [Reach.Effects.effect()], calls: [Reach.Map.EffectCall.t()]}
  def new(attrs), do: struct!(__MODULE__, attrs)
end
