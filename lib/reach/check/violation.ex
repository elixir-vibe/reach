defmodule Reach.Check.Violation do
  @moduledoc "Struct for an architecture policy violation."

  @derive Jason.Encoder
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

  def new(attrs) when is_list(attrs) or is_map(attrs), do: struct!(__MODULE__, attrs)
end
