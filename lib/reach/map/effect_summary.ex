defmodule Reach.Map.EffectSummary do
  @moduledoc "Struct for project-wide effect distribution."
  @derive JSON.Encoder
  defstruct [:total_calls, :distribution, :sources, :unknown_calls]
  def new(attrs), do: struct!(__MODULE__, attrs)
end
