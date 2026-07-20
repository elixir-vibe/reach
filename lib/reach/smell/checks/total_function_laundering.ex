defmodule Reach.Smell.Checks.TotalFunctionLaundering do
  @moduledoc "Detects private domain parsers that silently coerce invalid input to a valid value."

  use Reach.Smell.Check.AST

  alias Reach.Evidence.TotalFunctionLaundering
  alias Reach.Smell.Finding

  @impl true
  def kinds, do: [:total_function_laundering]

  defp scan_ast(ast, file) do
    ast
    |> TotalFunctionLaundering.collect_ast(file)
    |> Enum.reject(& &1.fallback_explicit?)
    |> Enum.map(&finding/1)
  end

  defp finding(fact) do
    catch_all = fact.catch_all
    line = catch_all.meta[:line] || 0

    Finding.new(
      kind: :total_function_laundering,
      message:
        "private #{fact.name}/1 catch-all silently coerces values outside #{inspect(Enum.sort(fact.inputs))} to #{inspect(fact.fallback)}; define accepted values in one module attribute, guard valid input, and raise or return an error for unsupported input",
      location: %{file: fact.file, line: line, column: catch_all.meta[:column]},
      evidence:
        Enum.map(fact.clauses, fn clause ->
          %{file: fact.file, line: clause.meta[:line] || 0, column: clause.meta[:column]}
        end),
      occurrences: length(fact.clauses),
      confidence: :high,
      source_range: %{
        file: fact.file,
        start_line: line,
        start_col: catch_all.meta[:column],
        end_line: line,
        end_col: catch_all.meta[:column]
      }
    )
  end
end
