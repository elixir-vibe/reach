defmodule Reach.Smell.Checks.EmptyMapNew do
  @moduledoc "Detects standalone Map.new/0 calls."

  @behaviour Reach.Smell.Check

  alias Reach.Smell.{Finding, Source}

  @message "Map.new/0 returns an empty map; use the %{} literal"

  @impl true
  def run(project) do
    project
    |> Source.module_files()
    |> Enum.uniq()
    |> Enum.flat_map(&file_findings/1)
  end

  defp file_findings(file) do
    if File.regular?(file) do
      file
      |> Source.cached_ast()
      |> walk(file, [])
      |> Enum.reverse()
      |> Enum.uniq_by(& &1.location)
    else
      []
    end
  rescue
    _error in [ArgumentError, File.Error, MatchError] -> []
  end

  defp walk({:|>, _meta, [left, _rhs]}, file, findings) do
    # The pipe supplies the first argument to the RHS call, so `|> Map.new()` is Map.new/1.
    walk(left, file, findings)
  end

  defp walk({:&, _meta, [{:/, _slash_meta, [_function, _arity]}]}, _file, findings) do
    # `&Map.new/0` is a function capture, not an empty map construction.
    findings
  end

  defp walk({:->, _meta, [patterns, body]}, file, findings) do
    # A Map.new/0-looking node on the left side of `->` is pattern/macro DSL syntax,
    # not an empty map construction expression.
    body
    |> walk(file, findings)
    |> then(fn findings -> walk_arrow_guards(patterns, file, findings) end)
  end

  defp walk(node, file, findings) when is_tuple(node) and tuple_size(node) == 3 do
    {_form, meta, args} = node

    findings =
      if empty_map_new?(node) do
        [finding(file, meta) | findings]
      else
        findings
      end

    if is_list(args) do
      Enum.reduce(args, findings, &walk(&1, file, &2))
    else
      findings
    end
  end

  defp walk({left, right}, file, findings) do
    findings
    |> then(&walk(left, file, &1))
    |> then(&walk(right, file, &1))
  end

  defp walk(nodes, file, findings) when is_list(nodes),
    do: Enum.reduce(nodes, findings, &walk(&1, file, &2))

  defp walk(_node, _file, findings), do: findings

  defp walk_arrow_guards(patterns, file, findings) do
    patterns
    |> List.wrap()
    |> Enum.flat_map(&guard_expression/1)
    |> Enum.reduce(findings, &walk(&1, file, &2))
  end

  defp guard_expression({:when, _meta, [_pattern, guard]}), do: [guard]
  defp guard_expression(_pattern), do: []

  defp empty_map_new?({{:., _, [{:__aliases__, _, [:Map]}, :new]}, _, []}), do: true
  defp empty_map_new?(_node), do: false

  defp finding(file, meta) do
    Finding.new(kind: :suboptimal, message: @message, location: "#{file}:#{meta[:line] || 0}")
  end
end
