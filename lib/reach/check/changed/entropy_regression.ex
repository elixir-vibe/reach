defmodule Reach.Check.Changed.EntropyRegression do
  @moduledoc "A parameter map-shape entropy increase in changed code."

  @derive JSON.Encoder
  @type t :: %__MODULE__{}
  defstruct [
    :target,
    :parameter,
    :parameter_index,
    :file,
    :line,
    :old_entropy,
    :new_entropy,
    :delta,
    old_variants: [],
    new_variants: [],
    changed_locations: []
  ]
end
