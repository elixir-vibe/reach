defmodule Reach.Evidence.PatternRunner do
  @moduledoc "Runs ExAST patterns for evidence providers."

  alias ExAST.Patcher

  def run(ast, specs, opts \\ []) do
    evidence_module = Keyword.fetch!(opts, :evidence_module)
    metadata = Map.new(specs, fn {name, spec} -> {name, spec} end)
    patterns = Map.new(specs, fn {name, {pattern, _builder}} -> {name, pattern} end)

    ast
    |> Patcher.find_many(patterns)
    |> Enum.flat_map(fn match ->
      {_pattern, builder} = Map.fetch!(metadata, match.pattern)
      match |> builder.() |> List.wrap() |> Enum.map(&struct_evidence(evidence_module, &1, match))
    end)
  end

  def match_meta(%{range: %{start: start}}) when is_list(start) do
    [line: start[:line], column: start[:column]]
  end

  def match_meta(%{node: {_form, meta, _args}}) when is_list(meta), do: meta
  def match_meta(_match), do: []

  defp struct_evidence(_evidence_module, nil, _match), do: nil
  defp struct_evidence(_evidence_module, false, _match), do: nil
  defp struct_evidence(_evidence_module, [], _match), do: nil

  defp struct_evidence(evidence_module, attrs, match) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)
    meta = Map.get(attrs, :meta) || match_meta(match)

    struct!(evidence_module, Map.put(attrs, :meta, meta))
  end
end
