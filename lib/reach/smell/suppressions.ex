defmodule Reach.Smell.Suppressions do
  @moduledoc "Filters smell findings using config and source-level suppressions."

  alias Reach.Check.Architecture
  alias Reach.Source.Suppression

  @all_tokens MapSet.new(["all", "smells"])

  def filter(findings, project, config) do
    source_suppressions = source_suppressions(findings)

    Enum.reject(findings, fn finding ->
      suppressed_by_config?(finding, config) or
        suppressed_by_source?(finding, source_suppressions) or
        suppressed_by_module?(finding, project, config)
    end)
  end

  def suppressed_by_source?(finding, source_suppressions) do
    with {file, line} when is_binary(file) and is_integer(line) <- location(finding),
         suppression <- Map.get(source_suppressions, file) do
      token = kind_token(finding)

      token_allowed?(
        MapSet.union(suppression.file, Map.get(suppression.lines, line, MapSet.new())),
        token
      )
    else
      _ -> false
    end
  end

  def suppressed_by_config?(finding, config) do
    case location(finding) do
      {file, _line} when is_binary(file) ->
        finding
        |> ignore_configs(config)
        |> Enum.any?(fn ignore ->
          ignore
          |> Keyword.get(:paths, [])
          |> List.wrap()
          |> Enum.any?(&Architecture.glob_match?(file, to_string(&1)))
        end)

      _ ->
        false
    end
  end

  def suppressed_by_module?(finding, project, config) do
    ignores = ignore_configs(finding, config)

    case finding_module(finding, project) do
      nil ->
        false

      module ->
        Enum.any?(ignores, fn ignore ->
          ignore
          |> Keyword.get(:modules, [])
          |> List.wrap()
          |> Enum.any?(&Architecture.module_matches_any?(module, [&1]))
        end)
    end
  end

  defp ignore_configs(finding, config) do
    smells = config.smells
    global_ignore = Map.get(smells, :ignore, [])
    per_check_ignore = per_check_ignore(smells, finding.kind)

    [global_ignore, per_check_ignore]
    |> Enum.filter(&Keyword.keyword?/1)
  end

  defp per_check_ignore(smells, kind) do
    smells
    |> Map.get(kind)
    |> case do
      value when is_map(value) -> Map.get(value, :ignore, [])
      _ -> []
    end
  end

  defp source_suppressions(findings) do
    findings
    |> Enum.flat_map(fn finding ->
      case location(finding) do
        {file, _line} when is_binary(file) -> [file]
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> Map.new(&{&1, parse_file(&1)})
  end

  defp parse_file(file) do
    file
    |> Suppression.parse_file()
    |> Enum.reduce(%{file: MapSet.new(), lines: %{}}, fn directive, acc ->
      tokens = MapSet.new(directive.tokens)

      case directive.scope do
        :file ->
          %{acc | file: MapSet.union(acc.file, tokens)}

        :next_line ->
          %{
            acc
            | lines:
                Map.update(acc.lines, directive.target_line, tokens, &MapSet.union(&1, tokens))
          }
      end
    end)
  end

  defp token_allowed?(tokens, kind) do
    not MapSet.disjoint?(tokens, @all_tokens) or MapSet.member?(tokens, kind)
  end

  defp kind_token(finding), do: Atom.to_string(finding.kind)

  defp finding_module(finding, project) do
    module_from_finding(finding) || module_from_location(finding, project)
  end

  defp module_from_finding(%{modules: [module | _]}) when is_atom(module), do: module
  defp module_from_finding(_finding), do: nil

  defp module_from_location(finding, project) do
    case location(finding) do
      {file, line} when is_binary(file) and is_integer(line) ->
        project.nodes
        |> Enum.map(fn {_id, node} -> node end)
        |> Enum.filter(&module_in_file?(&1, file))
        |> Enum.find_value(&module_at_line(&1, line))

      _ ->
        nil
    end
  end

  defp module_in_file?(node, file) do
    (node.type == :module_def and node.source_span) && node.source_span.file == file
  end

  defp module_at_line(node, line) do
    span = node.source_span

    if line >= span.start_line and (is_nil(span.end_line) or line <= span.end_line) do
      node.meta[:name]
    end
  end

  def location(%{location: %{file: file, line: line}}), do: {file, line}
  def location(%{location: %{file: file, start_line: line}}), do: {file, line}

  def location(%{location: location}) when is_binary(location) do
    case String.split(location, ":", parts: 3) do
      [file, line] -> {file, parse_line_number(line)}
      [file, line, _column] -> {file, parse_line_number(line)}
      _ -> {nil, nil}
    end
  end

  def location(_finding), do: {nil, nil}

  defp parse_line_number(line) do
    case Integer.parse(line) do
      {line, _rest} -> line
      :error -> nil
    end
  end
end
