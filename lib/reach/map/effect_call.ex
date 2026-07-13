defmodule Reach.Map.EffectCall do
  @moduledoc "Struct for a call site with its classified effect."
  @derive JSON.Encoder
  defstruct [:effect, :call]

  @type t :: %__MODULE__{effect: Reach.Effects.effect(), call: String.t()}
  def new(attrs), do: struct!(__MODULE__, attrs)
end
