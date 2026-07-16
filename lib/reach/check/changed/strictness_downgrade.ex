defmodule Reach.Check.Changed.StrictnessDowngrade do
  @moduledoc "Describes a changed-code erosion from strict to lenient map access."

  @derive JSON.Encoder
  @enforce_keys [:kind, :module, :function, :arity, :key, :file, :old_line, :new_line]
  defstruct [
    :kind,
    :module,
    :function,
    :arity,
    :variable,
    :parameter_index,
    :key,
    :file,
    :old_line,
    :new_line,
    :message,
    :suggestion,
    :malformed_callers,
    confidence: :high
  ]

  @type kind :: :field_to_get | :fetch_to_get | :pattern_to_get

  @type t :: %__MODULE__{
          kind: kind(),
          module: String.t(),
          function: atom(),
          arity: non_neg_integer(),
          variable: atom() | nil,
          parameter_index: non_neg_integer() | nil,
          key: atom(),
          file: Path.t(),
          old_line: pos_integer(),
          new_line: pos_integer(),
          message: String.t(),
          suggestion: String.t(),
          malformed_callers: [map()],
          confidence: :high
        }

  def new(attrs), do: struct!(__MODULE__, attrs)
end
