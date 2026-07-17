defmodule Reach.Smell.Checks.NilParameterWithoutGuard do
  @moduledoc "Detects nil-capable parameters used without a dominating non-nil guard."

  @behaviour Reach.Smell.Check

  alias Reach.Evidence
  alias Reach.Smell.Finding

  @impl true
  def kinds, do: [:nil_parameter_without_guard]

  @impl true
  def run(project) do
    project
    |> Evidence.nil_parameters()
    |> Enum.flat_map(&findings/1)
  end

  defp findings(fact) do
    fact.uses
    |> Enum.reject(& &1.safe?)
    |> Enum.map(&finding(fact, &1))
  end

  defp finding(fact, use) do
    parameter = to_string(fact.parameter)
    source = nil_source_label(List.first(use.nil_sources))

    Finding.new(
      kind: :nil_parameter_without_guard,
      message:
        "#{function_label(fact)} parameter #{parameter} is nil-capable but reaches #{use.operation} without a dominating non-nil guard",
      location: "#{use.file || fact.file}:#{use.line || fact.line}",
      evidence:
        "nil observed at #{source}; guard #{parameter} in a clause head or on every path before this use",
      confidence: :high
    )
  end

  defp function_label(fact),
    do: "#{inspect(fact.module)}.#{fact.function}/#{fact.arity}"

  defp nil_source_label(nil), do: "the function boundary"

  defp nil_source_label(source) do
    location = "#{source.file}:#{source.line}"

    case source.kind do
      :nil_argument -> "call site #{location}"
      :nil_default -> "default argument #{location}"
      :nil_clause -> "nil clause #{location}"
    end
  end
end
