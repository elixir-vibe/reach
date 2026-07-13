defmodule Reach.Smell.Checks.SchemaContractMismatch do
  @moduledoc "Detects contradictions between schema declarations and observed map access."

  @behaviour Reach.Smell.Check

  alias Reach.Evidence.MapContract
  alias Reach.MacroFact
  alias Reach.Smell.{Finding, Helpers}

  @impl true
  def kinds do
    [
      :mixed_schema_key_representation,
      :schema_undeclared_key_access,
      :schema_key_representation_mismatch,
      :required_schema_key_default
    ]
  end

  @impl true
  def run(project) do
    facts = MacroFact.collect_project(project)
    accesses = MapContract.collect_key_accesses(project)

    mixed_key_findings(facts) ++ usage_findings(facts, accesses, project)
  end

  defp mixed_key_findings(facts) do
    facts
    |> Enum.filter(&mixed_key_schema?/1)
    |> Enum.map(fn fact ->
      Finding.new(
        kind: :mixed_schema_key_representation,
        message:
          "#{fact.framework} schema mixes atom and string field keys; choose one boundary representation",
        location: source_location(fact.source),
        evidence: [source_location(fact.source)],
        keys: Enum.map(fact.data.fields, &elem(&1, 0)),
        confidence: :high
      )
    end)
  end

  defp usage_findings(facts, accesses, project) do
    facts
    |> Enum.filter(&schema_usage?/1)
    |> Enum.flat_map(fn fact ->
      observed = accesses_for_usage(accesses, fact.data.usage, project)

      undeclared_key_findings(fact, observed) ++
        representation_findings(fact, observed) ++ required_default_findings(fact, observed)
    end)
  end

  defp accesses_for_usage(accesses, usage, project) do
    input = usage.input

    Enum.filter(accesses, fn access ->
      access.function == usage.function and
        Enum.any?(access.map_origins, fn origin ->
          match?(%{type: :var, meta: %{name: ^input}}, project.nodes[origin])
        end)
    end)
  end

  defp undeclared_key_findings(fact, accesses) do
    declared = MapSet.new(fact.data.fields, fn {key, _representation} -> to_string(key) end)

    undeclared =
      accesses
      |> Enum.reject(&MapSet.member?(declared, &1.key_label))
      |> Enum.uniq_by(& &1.key_label)

    grouped_finding(
      fact,
      undeclared,
      :schema_undeclared_key_access,
      "code reads keys absent from the #{fact.framework} schema"
    )
  end

  defp representation_findings(%{data: %{key_representation: :mixed}}, _accesses), do: []

  defp representation_findings(fact, accesses) do
    mismatched =
      accesses
      |> Enum.filter(&(&1.representation in [:atom, :string]))
      |> Enum.reject(&(&1.representation == fact.data.key_representation))
      |> Enum.uniq_by(& &1.key_label)

    grouped_finding(
      fact,
      mismatched,
      :schema_key_representation_mismatch,
      "code uses a different key representation than the #{fact.framework} schema"
    )
  end

  defp required_default_findings(fact, accesses) do
    required = MapSet.new(fact.data.required_fields, &to_string/1)

    defaulted =
      accesses
      |> Enum.filter(&(&1.default_node && MapSet.member?(required, &1.key_label)))
      |> Enum.uniq_by(& &1.key_label)

    grouped_finding(
      fact,
      defaulted,
      :required_schema_key_default,
      "required schema fields are read with fallback defaults"
    )
  end

  defp grouped_finding(_fact, [], _kind, _message), do: []

  defp grouped_finding(fact, accesses, kind, message) do
    keys = Enum.map(accesses, & &1.key_label)

    [
      Finding.new(
        kind: kind,
        message: "#{message}: #{Enum.map_join(keys, ", ", &inspect/1)}",
        location: source_location(fact.source),
        evidence: Enum.map(accesses, &Helpers.location(&1.node)),
        keys: keys,
        confidence: :high
      )
    ]
  end

  defp schema_usage?(%MacroFact{
         kind: :schema_declaration,
         data: %{usage: %{function: function, input: input}}
       })
       when not is_nil(function) and not is_nil(input),
       do: true

  defp schema_usage?(_fact), do: false

  defp mixed_key_schema?(%MacroFact{
         kind: :schema_declaration,
         data: %{key_representation: :mixed}
       }),
       do: true

  defp mixed_key_schema?(_fact), do: false

  defp source_location(%{file: file, line: line}), do: "#{file}:#{line}"
  defp source_location(%{line: line}), do: "line #{line}"
  defp source_location(_source), do: "unknown"
end
