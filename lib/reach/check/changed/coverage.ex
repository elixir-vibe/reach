defmodule Reach.Check.Changed.Coverage do
  @moduledoc "Assessment coverage for changed-code analysis."

  alias Reach.Check.Changed.Range
  alias Reach.Project.Query

  @type confidence :: :high | :partial | :none

  @derive JSON.Encoder
  defstruct [
    :confidence,
    :coverage_percent,
    :changed_line_count,
    :assessed_line_count,
    :unassessed_line_count,
    :added_line_count,
    :deleted_line_count,
    :changed_file_count,
    :fully_assessed_file_count,
    :partially_assessed_file_count,
    :unassessed_file_count,
    :assessed_range_count,
    :partially_assessed_range_count,
    :unassessed_range_count,
    unassessed_files: []
  ]

  @type t :: %__MODULE__{
          confidence: confidence(),
          coverage_percent: float(),
          changed_line_count: non_neg_integer(),
          assessed_line_count: non_neg_integer(),
          unassessed_line_count: non_neg_integer(),
          added_line_count: non_neg_integer(),
          deleted_line_count: non_neg_integer(),
          changed_file_count: non_neg_integer(),
          fully_assessed_file_count: non_neg_integer(),
          partially_assessed_file_count: non_neg_integer(),
          unassessed_file_count: non_neg_integer(),
          assessed_range_count: non_neg_integer(),
          partially_assessed_range_count: non_neg_integer(),
          unassessed_range_count: non_neg_integer(),
          unassessed_files: [Path.t()]
        }

  @spec analyze(
          [Path.t()],
          %{optional(Path.t()) => [Range.t() | {pos_integer(), pos_integer()}]},
          [Reach.IR.Node.t()]
        ) :: t()
  def analyze(changed_files, ranges_by_file, function_nodes) do
    files = Enum.uniq(changed_files ++ Map.keys(ranges_by_file))

    file_stats =
      Map.new(files, fn file ->
        ranges = Enum.map(Map.get(ranges_by_file, file, []), &Range.normalize/1)
        functions = functions_for_file(function_nodes, file)
        {file, file_stats(ranges, functions)}
      end)

    changed_lines = sum_stat(file_stats, :changed)
    assessed_lines = sum_stat(file_stats, :assessed)
    unassessed_lines = changed_lines - assessed_lines

    file_counts = Enum.frequencies_by(file_stats, fn {_file, stats} -> stats.status end)
    range_counts = sum_range_counts(file_stats)

    %__MODULE__{
      confidence: confidence(files, changed_lines, assessed_lines),
      coverage_percent: coverage_percent(files, changed_lines, assessed_lines),
      changed_line_count: changed_lines,
      assessed_line_count: assessed_lines,
      unassessed_line_count: unassessed_lines,
      added_line_count: sum_stat(file_stats, :added),
      deleted_line_count: sum_stat(file_stats, :deleted),
      changed_file_count: length(files),
      fully_assessed_file_count: Map.get(file_counts, :full, 0),
      partially_assessed_file_count: Map.get(file_counts, :partial, 0),
      unassessed_file_count: Map.get(file_counts, :none, 0),
      assessed_range_count: range_counts.full,
      partially_assessed_range_count: range_counts.partial,
      unassessed_range_count: range_counts.none,
      unassessed_files:
        file_stats
        |> Enum.filter(fn {_file, stats} -> stats.status != :full end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()
    }
  end

  defp functions_for_file(function_nodes, file) do
    function_nodes
    |> Enum.filter(fn function ->
      function.source_span && Query.file_matches?(function.source_span.file, file)
    end)
    |> Enum.sort_by(& &1.source_span.start_line)
  end

  defp file_stats([], _functions) do
    %{status: :none, changed: 0, assessed: 0, added: 0, deleted: 0, ranges: empty_counts()}
  end

  defp file_stats(ranges, functions) do
    stats = Enum.map(ranges, &range_stats(&1, functions))
    changed = Enum.sum_by(stats, & &1.changed)
    assessed = Enum.sum_by(stats, & &1.assessed)

    %{
      status: assessment_status(changed, assessed),
      changed: changed,
      assessed: assessed,
      added: Enum.sum_by(ranges, & &1.new_count),
      deleted: Enum.sum_by(ranges, & &1.old_count),
      ranges: Enum.frequencies_by(stats, & &1.status)
    }
  end

  defp range_stats(range, functions) do
    changed = Range.change_line_count(range)
    assessed = min(assessed_current_lines(range, functions), changed)
    %{status: assessment_status(changed, assessed), changed: changed, assessed: assessed}
  end

  defp assessed_current_lines(%Range{new_count: 0}, _functions), do: 0

  defp assessed_current_lines(%Range{} = range, functions) do
    first = range.new_start
    last = first + range.new_count - 1

    Enum.reduce_while(functions, 0, fn function, _assessed ->
      line = function.source_span.start_line

      cond do
        line <= first -> {:halt, range.new_count}
        line <= last -> {:halt, last - line + 1}
        true -> {:halt, 0}
      end
    end)
  end

  defp assessment_status(0, _assessed), do: :none
  defp assessment_status(changed, assessed) when changed == assessed, do: :full
  defp assessment_status(_changed, 0), do: :none
  defp assessment_status(_changed, _assessed), do: :partial

  defp confidence([], 0, 0), do: :high
  defp confidence(_files, _changed, 0), do: :none
  defp confidence(_files, changed, assessed) when changed == assessed, do: :high
  defp confidence(_files, _changed, _assessed), do: :partial

  defp coverage_percent([], 0, 0), do: 100.0
  defp coverage_percent(_files, 0, _assessed), do: 0.0

  defp coverage_percent(_files, changed, assessed) do
    Float.round(assessed * 100 / changed, 1)
  end

  defp sum_stat(file_stats, key) do
    Enum.sum_by(file_stats, fn {_file, stats} -> Map.fetch!(stats, key) end)
  end

  defp sum_range_counts(file_stats) do
    Enum.reduce(file_stats, empty_counts(), fn {_file, stats}, counts ->
      %{
        full: counts.full + Map.get(stats.ranges, :full, 0),
        partial: counts.partial + Map.get(stats.ranges, :partial, 0),
        none: counts.none + Map.get(stats.ranges, :none, 0)
      }
    end)
  end

  defp empty_counts, do: %{full: 0, partial: 0, none: 0}
end
