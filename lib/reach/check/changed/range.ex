defmodule Reach.Check.Changed.Range do
  @moduledoc "Represents old- and new-side line counts for a changed diff hunk."

  @enforce_keys [:old_start, :old_count, :new_start, :new_count]
  defstruct [:old_start, :old_count, :new_start, :new_count]

  @type t :: %__MODULE__{
          old_start: non_neg_integer(),
          old_count: non_neg_integer(),
          new_start: non_neg_integer(),
          new_count: non_neg_integer()
        }

  @spec new(keyword() | map()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)

  @spec normalize(t() | {pos_integer(), pos_integer()}) :: t()
  def normalize(%__MODULE__{} = range), do: range

  def normalize({first, last})
      when is_integer(first) and is_integer(last) and first <= last do
    new(old_start: first, old_count: 0, new_start: first, new_count: last - first + 1)
  end

  @spec current_lines(t()) :: {non_neg_integer(), non_neg_integer()} | nil
  def current_lines(%__MODULE__{new_count: 0}), do: nil

  def current_lines(%__MODULE__{new_start: start, new_count: count}) do
    {start, start + count - 1}
  end

  @spec change_line_count(t()) :: non_neg_integer()
  def change_line_count(%__MODULE__{} = range), do: max(range.old_count, range.new_count)
end
