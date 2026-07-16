defmodule ReachCalibration.Selection do
  @moduledoc "A reproducible package-version selection and its provenance."

  @enforce_keys [:versions, :strategy, :pool_size]
  defstruct [:versions, :strategy, :pool_size, patterns: []]

  @type t :: %__MODULE__{
          versions: [map()],
          strategy: :all | :stratified,
          pool_size: non_neg_integer(),
          patterns: [String.t()]
        }
end
