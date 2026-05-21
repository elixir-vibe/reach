defmodule Reach.Evidence.Fact do
  @moduledoc "A reusable evidence fact emitted by evidence providers."

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
