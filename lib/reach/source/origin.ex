defmodule Reach.Source.Origin do
  @moduledoc "Origin metadata for AST lowered from framework or template syntax."

  @type t :: %__MODULE__{
          language: atom(),
          kind: atom(),
          label: String.t() | nil,
          span: Reach.Source.Span.t() | map() | nil,
          plugin: module() | nil,
          generated?: boolean()
        }

  defstruct [:language, :kind, :label, :span, :plugin, generated?: false]
end
