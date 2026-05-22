defmodule Reach.Smell.Checks.StandardLibraryBypass do
  @moduledoc "Detects ad-hoc implementations that bypass standard library helpers."

  use Reach.Smell.Check.AST

  alias Reach.Evidence.StandardLibraryBypass
  alias Reach.Smell.Finding

  @impl true
  def kinds, do: StandardLibraryBypass.kinds()

  defp scan_ast(ast, file) do
    ast
    |> StandardLibraryBypass.collect_ast()
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
    line = if is_list(meta), do: meta[:line], else: nil
    column = if is_list(meta), do: meta[:column], else: nil
    %{file: file, line: line, column: column}
  end
end
