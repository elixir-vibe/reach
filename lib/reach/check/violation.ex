defmodule Reach.Check.Violation do
  @moduledoc "Struct for an architecture policy violation."

  @derive JSON.Encoder
  defstruct [
    :type,
    :caller_module,
    :caller_layer,
    :callee_module,
    :callee_layer,
    :file,
    :line,
    :call,
    :layers,
    :edges,
    :matched_layers,
    :module,
    :function,
    :allowed_effects,
    :actual_effects,
    :disallowed_effects,
    :rule,
    :key,
    :path,
    :message
  ]

  @type t :: %__MODULE__{
          allowed_effects: [Reach.Effects.effect()] | nil,
          actual_effects: [Reach.Effects.effect()] | nil,
          disallowed_effects: [Reach.Effects.effect()] | nil
        }

  def new(attrs) when is_list(attrs) or is_map(attrs), do: struct!(__MODULE__, attrs)
end
