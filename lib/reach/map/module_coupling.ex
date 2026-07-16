defmodule Reach.Map.ModuleCoupling do
  @moduledoc "Struct for per-module coupling detail."
  @derive JSON.Encoder
  defstruct [:name, :file, :afferent, :efferent, :instability]

  @type t :: %__MODULE__{
          name: String.t(),
          file: String.t() | nil,
          afferent: non_neg_integer(),
          efferent: non_neg_integer(),
          instability: float()
        }

  def new(attrs), do: struct!(__MODULE__, attrs)
end
