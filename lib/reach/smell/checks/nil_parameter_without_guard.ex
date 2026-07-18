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
    |> Enum.filter(&promoted?(fact, &1))
    |> Enum.map(&finding(fact, &1))
  end

  defp promoted?(fact, use) do
    Enum.any?(use.nil_sources, fn source ->
      case source.kind do
        :nil_default ->
          not private_recursive_conditional?(fact, use)

        :nil_clause ->
          use.bare_parameter? and not use.parameter_guarded? and
            source.file == use.file and source.line > use.line

        :nil_argument ->
          direct_argument_hazard?(use) or gated_project_hazard?(use)
      end
    end)
  end

  defp private_recursive_conditional?(fact, use),
    do: fact.visibility == :private and fact.recursive? and use.conditional?

  defp direct_argument_hazard?(use) do
    use.bare_parameter? and not use.parameter_guarded? and
      not use.companion_restricted? and not use.conditional?
  end

  defp gated_project_hazard?(use),
    do: use.project_target? and use.literal_companion_gate?

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
