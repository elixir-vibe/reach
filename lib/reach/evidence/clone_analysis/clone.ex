defmodule Reach.Evidence.CloneAnalysis.Clone do
  @moduledoc "Struct for a clone family (a group of similar code fragments)."

  @derive Jason.Encoder
  defstruct [:type, :mass, :similarity, :fragments, :suggestion]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
