defmodule Reach.Smell.Finding do
  @moduledoc "Struct for smell check findings with location and evidence."

  @enforce_keys [:kind, :message, :location]
  @derive {JSON.Encoder,
           only: [
             :kind,
             :message,
             :location,
             :evidence,
             :keys,
             :occurrences,
             :modules,
             :callbacks,
             :confidence
           ]}
  defstruct [
    :kind,
    :message,
    :location,
    :evidence,
    :keys,
    :occurrences,
    :modules,
    :callbacks,
    :confidence,
    :source_range
  ]

  def new(attrs) when is_list(attrs) or is_map(attrs) do
    struct!(__MODULE__, attrs)
  end
end
