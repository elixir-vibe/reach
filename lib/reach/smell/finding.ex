defmodule Reach.Smell.Finding do
  @moduledoc "Struct for smell check findings with location and evidence."

  @type remediation_safety :: :equivalent | :conditional | :review_only

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
             :confidence,
             :remediation_safety
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
    :source_range,
    remediation_safety: :review_only
  ]

  def new(attrs) when is_list(attrs) or is_map(attrs) do
    finding = struct!(__MODULE__, attrs)

    if finding.remediation_safety in [:equivalent, :conditional, :review_only] do
      finding
    else
      raise ArgumentError,
            "remediation_safety must be :equivalent, :conditional, or :review_only"
    end
  end
end
