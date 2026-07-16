defmodule Reach.Evidence.Fact do
  @moduledoc "A reusable evidence fact emitted by evidence providers."

  @type t :: %__MODULE__{
          family: atom() | nil,
          kind: atom() | nil,
          message: String.t() | nil,
          replacement: String.t() | nil,
          meta: keyword() | map() | nil,
          confidence: atom() | nil,
          source: term(),
          data: map() | nil
        }

  defstruct [
    :family,
    :kind,
    :message,
    :replacement,
    :meta,
    :confidence,
    :source,
    :data
  ]
end
