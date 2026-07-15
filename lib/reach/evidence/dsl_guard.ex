defmodule Reach.Evidence.DSLGuard do
  @moduledoc "Filters generic evidence emitted from source ranges with reinterpreted DSL semantics."

  alias Reach.Config
  alias Reach.Source.DSLGuard, as: SourceGuard

  @spec filter([map()], Macro.t(), [module()], Config.t() | keyword()) :: [map()]
  def filter(evidence, ast, plugins, config \\ []) do
    config = Config.normalize(config)
    shapes = config.smells.dsl_macros

    if SourceGuard.enabled?(plugins, shapes) do
      ranges = SourceGuard.ranges(ast, plugins, shapes)
      Enum.reject(evidence, &guarded?(&1, ranges))
    else
      evidence
    end
  end

  defp guarded?(evidence, ranges) do
    case evidence_position(evidence) do
      {line, column} when is_integer(line) ->
        SourceGuard.guarded_position?(ranges, line, column)

      _position ->
        false
    end
  end

  defp evidence_position(%{meta: meta}), do: position(meta)
  defp evidence_position(%{location: location}), do: position(location)
  defp evidence_position(_evidence), do: nil

  defp position(position) when is_list(position),
    do: {position[:line], position[:column]}

  defp position(%{line: line} = position), do: {line, Map.get(position, :column)}
  defp position(%{start_line: line} = position), do: {line, Map.get(position, :start_column)}
  defp position(_position), do: nil
end
