defmodule Reach.Smell.DSLGuard do
  @moduledoc "Filters generic smell findings inside AST regions with reinterpreted DSL semantics."

  alias Reach.Config
  alias Reach.Smell.{Source, Suppressions}
  alias Reach.Source.DSLGuard, as: SourceGuard

  @spec filter([map()], Reach.Project.t(), Config.t() | keyword(), MapSet.t(atom())) :: [map()]
  def filter(findings, project, config, exempt_kinds \\ MapSet.new()) do
    config = Config.normalize(config)
    plugins = Map.get(project, :plugins, [])
    shapes = config.smells.dsl_macros

    if SourceGuard.enabled?(plugins, shapes) do
      ranges = guarded_ranges(findings, project, plugins, shapes, exempt_kinds)

      Enum.reject(findings, fn finding ->
        not MapSet.member?(exempt_kinds, finding.kind) and guarded_finding?(finding, ranges)
      end)
    else
      findings
    end
  end

  defp guarded_ranges(findings, project, plugins, shapes, exempt_kinds) do
    project_files = Map.new(Source.module_files(project), &{Path.expand(&1), &1})

    findings
    |> Enum.flat_map(&candidate_file(&1, exempt_kinds))
    |> Enum.uniq()
    |> Enum.flat_map(fn expanded_file ->
      case Map.fetch(project_files, expanded_file) do
        {:ok, file} ->
          [{expanded_file, SourceGuard.ranges(Source.cached_ast(file), plugins, shapes)}]

        :error ->
          []
      end
    end)
    |> Map.new()
  end

  defp candidate_file(finding, exempt_kinds) do
    if MapSet.member?(exempt_kinds, finding.kind) do
      []
    else
      finding |> Suppressions.location() |> location_file()
    end
  end

  defp location_file({file, line}) when is_binary(file) and is_integer(line),
    do: [Path.expand(file)]

  defp location_file(_location), do: []

  defp guarded_finding?(finding, ranges) do
    case Suppressions.location(finding) do
      {file, line} when is_binary(file) and is_integer(line) ->
        ranges
        |> Map.get(Path.expand(file), [])
        |> SourceGuard.guarded_position?(line, finding_column(finding))

      _location ->
        false
    end
  end

  defp finding_column(%{source_range: %{start: start_position}}) when is_list(start_position),
    do: start_position[:column]

  defp finding_column(%{source_range: %{start_column: column}}), do: column
  defp finding_column(%{source_range: %{start_col: column}}), do: column
  defp finding_column(_finding), do: nil
end
