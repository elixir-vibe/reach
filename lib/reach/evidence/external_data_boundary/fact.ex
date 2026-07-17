defmodule Reach.Evidence.ExternalDataBoundary.Fact do
  @moduledoc "A decoded external value observed crossing a storage or process boundary."

  @type t :: %__MODULE__{
          source: String.t(),
          source_line: pos_integer() | nil,
          boundary: String.t(),
          boundary_kind: :storage | :process,
          file: Path.t(),
          line: pos_integer() | nil,
          column: pos_integer() | nil,
          variables: [atom()],
          consumer_keys: [String.t()]
        }

  @enforce_keys [:source, :boundary, :boundary_kind, :file]
  defstruct [
    :source,
    :source_line,
    :boundary,
    :boundary_kind,
    :file,
    :line,
    :column,
    variables: [],
    consumer_keys: []
  ]
end
