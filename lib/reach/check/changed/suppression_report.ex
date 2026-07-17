defmodule Reach.Check.Changed.SuppressionReport do
  @moduledoc "Summarizes source suppression changes in a diff."

  @derive JSON.Encoder
  defstruct added: [],
            removed: [],
            reasonless_added: [],
            unchanged_count: 0,
            total_before: 0,
            total_after: 0

  @type t :: %__MODULE__{
          added: [Reach.Source.Suppression.Directive.t()],
          removed: [Reach.Source.Suppression.Directive.t()],
          reasonless_added: [Reach.Source.Suppression.Directive.t()],
          unchanged_count: non_neg_integer(),
          total_before: non_neg_integer(),
          total_after: non_neg_integer()
        }

  def new(attrs), do: struct!(__MODULE__, attrs)
end
