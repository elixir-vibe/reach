defmodule Reach.Evidence.CloneAnalysis.Clone do
  @moduledoc "Struct for a clone family (a group of similar code fragments)."

  @derive JSON.Encoder
  @type t :: %__MODULE__{
          type: atom() | nil,
          mass: number() | nil,
          similarity: number() | nil,
          fragments: [Reach.Evidence.CloneAnalysis.Fragment.t()],
          suggestion: term()
        }
  defstruct [:type, :mass, :similarity, :fragments, :suggestion]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
