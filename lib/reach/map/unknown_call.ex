defmodule Reach.Map.UnknownCall do
  @moduledoc "Struct for a call with unresolved effect classification."
  @derive JSON.Encoder
  defstruct [:module, :function, :kind, :count]
  def new(attrs), do: struct!(__MODULE__, attrs)
end
