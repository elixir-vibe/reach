defmodule Reach.IR.Counter do
  @moduledoc "Monotonic ID counter for IR node construction."

  @opaque t :: :atomics.atomics_ref()

  @spec new() :: t()
  @spec new(non_neg_integer()) :: t()
  def new(initial_value \\ 0) do
    ref = :atomics.new(1, signed: true)
    :ok = :atomics.put(ref, 1, initial_value)
    ref
  end

  @spec next(t()) :: non_neg_integer()
  def next(ref) do
    :atomics.add_get(ref, 1, 1) - 1
  end
end
