defmodule Reach.Plugins.Jason.Smells.HandRolledEncoder do
  @moduledoc "Detects hand-rolled JSON encoding that should live behind Jason encoders."

  use Reach.Smell.Check.AST

  alias Reach.Plugins.Jason.Evidence.HandRolledEncoder
  alias Reach.Smell.Finding

  @impl true
  def kinds, do: HandRolledEncoder.kinds()

  defp scan_ast(ast, file) do
    ast
    |> HandRolledEncoder.collect_ast()
    |> Enum.map(&finding(&1, file))
  end

  defp finding(evidence, file) do
    Finding.new(
      kind: evidence.kind,
      message: evidence.message,
      location: location(file, evidence.meta),
      evidence: evidence.replacement,
      confidence: evidence.confidence
    )
  end

  defp location(file, meta) do
    %{file: file, line: meta[:line], column: meta[:column]}
  end
end
