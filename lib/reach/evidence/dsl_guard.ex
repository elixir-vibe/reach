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
    case evidence_line(evidence) do
      line when is_integer(line) -> SourceGuard.guarded_line?(ranges, line)
      _line -> false
    end
  end

  defp evidence_line(%{meta: meta}), do: position_line(meta)
  defp evidence_line(%{location: location}), do: position_line(location)
  defp evidence_line(_evidence), do: nil

  defp position_line(position) when is_list(position), do: position[:line]
  defp position_line(%{line: line}), do: line
  defp position_line(%{start_line: line}), do: line
  defp position_line(_position), do: nil
end
