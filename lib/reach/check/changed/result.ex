defmodule Reach.Check.Changed.Result do
  @moduledoc "Struct for changed-code analysis results."

  @derive JSON.Encoder
  defstruct [
    :base,
    :risk,
    :risk_reasons,
    :confidence,
    :coverage,
    :changed_files,
    :changed_functions,
    :public_api_changes,
    :suggested_tests,
    strictness_downgrades: [],
    displaced_facts: [],
    suppression_report: %Reach.Check.Changed.SuppressionReport{}
  ]

  @type t :: %__MODULE__{
          base: String.t(),
          risk: :high | :medium | :low,
          risk_reasons: [String.t()],
          confidence: Reach.Check.Changed.Coverage.confidence(),
          coverage: Reach.Check.Changed.Coverage.t(),
          changed_files: [Path.t()],
          changed_functions: [Reach.Check.Changed.Function.t()],
          public_api_changes: [Reach.Check.Changed.Function.t()],
          strictness_downgrades: [Reach.Check.Changed.StrictnessDowngrade.t()],
          displaced_facts: [Reach.Check.Changed.DisplacedFact.t()],
          suppression_report: Reach.Check.Changed.SuppressionReport.t(),
          suggested_tests: [Path.t()]
        }

  def new(attrs), do: struct!(__MODULE__, attrs)
end
