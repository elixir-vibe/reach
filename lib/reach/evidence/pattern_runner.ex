defmodule Reach.Evidence.PatternRunner do
  @moduledoc "Runs ExAST patterns for evidence providers."

  alias ExAST.Patcher
  alias Reach.Evidence.Fact

  def run(ast, specs, opts \\ []) do
    evidence_module = Keyword.get(opts, :evidence_module, Fact)
    family = Keyword.get(opts, :family)
    metadata = Map.new(specs, fn {name, spec} -> {name, spec} end)
    patterns = Map.new(specs, fn {name, {pattern, _builder}} -> {name, pattern} end)

    ast
    |> find_many(patterns)
    |> Enum.flat_map(fn match ->
      {_pattern, builder} = Map.fetch!(metadata, match.pattern)

      match
      |> builder.()
      |> List.wrap()
      |> Enum.map(&struct_evidence(evidence_module, family, &1, match))
      |> Enum.reject(&is_nil/1)
    end)
  end

  defp find_many(ast, patterns) do
    Patcher.find_many(ast, patterns)
  rescue
    FunctionClauseError -> []
    ArgumentError -> []
  end

  def match_meta(%{range: %{start: start}}) when is_list(start) do
    [line: start[:line], column: start[:column]]
  end

  def match_meta(%{node: {_form, meta, _args}}) when is_list(meta), do: meta
  def match_meta(_match), do: []

  defp struct_evidence(_evidence_module, _family, nil, _match), do: nil
  defp struct_evidence(_evidence_module, _family, false, _match), do: nil
  defp struct_evidence(_evidence_module, _family, [], _match), do: nil

  defp struct_evidence(evidence_module, family, attrs, match)
       when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)
    meta = Map.get(attrs, :meta) || match_meta(match)

    evidence_module
    |> struct()
    |> Map.from_struct()
    |> maybe_put_family(attrs, family)
    |> Map.put(:meta, meta)
    |> then(&struct!(evidence_module, &1))
  end

  defp maybe_put_family(struct_fields, attrs, family) do
    if Map.has_key?(struct_fields, :family) do
      Map.put_new(attrs, :family, family)
    else
      attrs
    end
  end
end
