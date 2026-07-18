defmodule Reach.Smell.Checks.DualKeyFallback do
  @moduledoc "Detects repeated literal atom/string fallbacks and false-collapsing lookups."

  @behaviour Reach.Smell.Check

  alias Reach.Evidence.MapContract
  alias Reach.Smell.{Finding, Helpers}

  @minimum_fallback_sites 2

  @impl true
  def kinds, do: [:dual_key_fallback, :false_collapsing_lookup]

  @impl true
  def run(project) do
    fallbacks = project |> MapContract.collect_fallbacks() |> Enum.filter(& &1.returned?)
    fallbacks_by_node = Enum.group_by(fallbacks, & &1.node.id)
    false_collapse_nodes = false_collapse_nodes(fallbacks_by_node)

    grouped_dual_key_findings(fallbacks, false_collapse_nodes) ++
      false_collapse_findings(fallbacks_by_node, false_collapse_nodes)
  end

  defp grouped_dual_key_findings(fallbacks, false_collapse_nodes) do
    fallbacks
    |> Enum.reject(&MapSet.member?(false_collapse_nodes, &1.node.id))
    |> Enum.filter(&literal_key_fallback?/1)
    |> Enum.group_by(&{&1.function, fallback_map_origins(&1)})
    |> Enum.filter(fn {_function_origin, function_fallbacks} ->
      fallback_site_count(function_fallbacks) >= @minimum_fallback_sites
    end)
    |> Enum.map(fn {_function_origin, function_fallbacks} ->
      dual_key_finding(function_fallbacks)
    end)
  end

  defp fallback_map_origins(fallback) do
    fallback.accesses |> List.first() |> Map.fetch!(:map_origins)
  end

  defp literal_key_fallback?(fallback) do
    match?({:literal, _key}, fallback.accesses |> List.first() |> Map.fetch!(:logical_key))
  end

  defp dual_key_finding(fallbacks) do
    fallback = earliest_fallback(fallbacks)

    keys =
      fallbacks
      |> Enum.map(&(&1.accesses |> List.first() |> Map.fetch!(:key_label)))
      |> Enum.uniq()
      |> Enum.sort()

    Finding.new(
      kind: :dual_key_fallback,
      message:
        "#{format_target(fallback.function)} repeatedly reads literal map keys #{Enum.map_join(keys, ", ", &inspect/1)} through atom/string fallbacks; normalize the input map once before reading its fields",
      location: Helpers.location(fallback.node),
      evidence: Enum.flat_map(fallbacks, &evidence/1) |> Enum.uniq(),
      keys: keys,
      occurrences: fallback_site_count(fallbacks),
      confidence: :medium
    )
  end

  defp fallback_site_count(fallbacks) do
    fallbacks |> Enum.map(& &1.node.id) |> Enum.uniq() |> length()
  end

  defp earliest_fallback(fallbacks) do
    Enum.min_by(fallbacks, fn fallback ->
      case fallback.node.source_span do
        %{file: file, start_line: line} = span -> {file, line, Map.get(span, :start_col) || 0}
        _span -> {"", 0, 0}
      end
    end)
  end

  defp false_collapse_nodes(fallbacks_by_node) do
    fallbacks_by_node
    |> Enum.filter(fn {_node_id, fallbacks} -> false_collapse?(fallbacks) end)
    |> Enum.map(&elem(&1, 0))
    |> MapSet.new()
  end

  defp false_collapse?(fallbacks) do
    Enum.any?(fallbacks, &(&1.operator == :or and &1.default? and &1.boolean_evidence != []))
  end

  defp false_collapse_findings(fallbacks_by_node, false_collapse_nodes) do
    false_collapse_nodes
    |> Enum.sort()
    |> Enum.map(fn node_id -> false_collapse_finding(Map.fetch!(fallbacks_by_node, node_id)) end)
  end

  defp false_collapse_finding(fallbacks) do
    fallback = List.first(fallbacks)

    Finding.new(
      kind: :false_collapsing_lookup,
      message:
        "Map.get/2 results are chained with || before a default; an explicit false value is treated as missing",
      location: Helpers.location(fallback.node),
      evidence: Enum.flat_map(fallbacks, &evidence/1) |> Enum.uniq(),
      confidence: :high
    )
  end

  defp evidence(fallback) do
    Enum.map(fallback.accesses, &Helpers.location(&1.node)) |> Enum.uniq()
  end

  defp format_target({module, name, arity}), do: "#{inspect(module)}.#{name}/#{arity}"
end
