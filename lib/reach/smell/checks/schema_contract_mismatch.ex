defmodule Reach.Smell.Checks.SchemaContractMismatch do
  @moduledoc "Detects contradictory key representations in normalized schema facts."

  @behaviour Reach.Smell.Check

  alias Reach.MacroFact
  alias Reach.Smell.Finding

  @impl true
  def kinds, do: [:mixed_schema_key_representation]

  @impl true
  def run(project) do
    project
    |> MacroFact.collect_project()
    |> Enum.filter(&mixed_key_schema?/1)
    |> Enum.map(&finding/1)
  end

  defp mixed_key_schema?(%MacroFact{
         kind: :schema_declaration,
         data: %{key_representation: :mixed}
       }),
       do: true

  defp mixed_key_schema?(_fact), do: false

  defp finding(fact) do
    Finding.new(
      kind: :mixed_schema_key_representation,
      message:
        "#{fact.framework} schema mixes atom and string field keys; choose one boundary representation",
      location: source_location(fact.source),
      evidence: [source_location(fact.source)],
      keys: Enum.map(fact.data.fields, &elem(&1, 0)),
      confidence: :high
    )
  end

  defp source_location(%{file: file, line: line}), do: "#{file}:#{line}"
  defp source_location(%{line: line}), do: "line #{line}"
  defp source_location(_source), do: "unknown"
end
