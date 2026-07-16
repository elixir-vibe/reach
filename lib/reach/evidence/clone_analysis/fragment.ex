defmodule Reach.Evidence.CloneAnalysis.Fragment do
  @moduledoc "Struct for a single code fragment within a clone family."

  @derive JSON.Encoder
  @type t :: %__MODULE__{}
  defstruct [
    :file,
    :line,
    :origin,
    :dependency,
    :module,
    :function,
    :arity,
    :effects,
    :effect_sequence,
    :calls,
    :return_shapes,
    :map_accesses,
    :validation_calls,
    :mass
  ]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
