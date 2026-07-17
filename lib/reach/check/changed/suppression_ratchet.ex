defmodule Reach.Check.Changed.SuppressionRatchet do
  @moduledoc "Compares source suppression directives across changed hunks."

  alias Reach.Check.Changed.Range
  alias Reach.Check.Changed.SourceSnapshot
  alias Reach.Check.Changed.SuppressionReport
  alias Reach.Source.Suppression

  @spec analyze(String.t(), map(), keyword()) :: SuppressionReport.t()
  def analyze(base, changed_ranges, opts \\ []) do
    revision = SourceSnapshot.revision(base, opts)

    {old_directives, new_directives} =
      changed_ranges
      |> changed_source_files()
      |> Enum.reduce({[], []}, fn file, {old_acc, new_acc} ->
        old = directives(:old, file, revision, opts)
        new = directives(:new, file, revision, opts)
        {Enum.reverse(old, old_acc), Enum.reverse(new, new_acc)}
      end)

    added = changed_delta(new_directives, old_directives, changed_ranges, :new)
    removed = changed_delta(old_directives, new_directives, changed_ranges, :old)

    SuppressionReport.new(
      added: sort_directives(added),
      removed: sort_directives(removed),
      reasonless_added: added |> Enum.filter(&is_nil(&1.reason)) |> sort_directives(),
      unchanged_count: unchanged_count(old_directives, new_directives),
      total_before: length(old_directives),
      total_after: length(new_directives)
    )
  end

  defp directives(side, file, revision, opts) do
    case SourceSnapshot.source(side, file, revision, opts) do
      {:ok, source} -> Suppression.parse_source(source, file)
      {:error, _reason} -> []
    end
  end

  defp changed_delta(primary, comparison, changed_ranges, side) do
    primary_counts = frequencies(primary)
    comparison_counts = frequencies(comparison)

    primary
    |> Enum.filter(&changed_directive?(&1, changed_ranges, side))
    |> Enum.group_by(&identity/1)
    |> Enum.flat_map(fn {identity, directives} ->
      excess =
        max(Map.get(primary_counts, identity, 0) - Map.get(comparison_counts, identity, 0), 0)

      Enum.take(directives, excess)
    end)
  end

  defp unchanged_count(old_directives, new_directives) do
    old_counts = frequencies(old_directives)
    new_counts = frequencies(new_directives)

    Enum.sum_by(old_counts, fn {identity, count} ->
      min(count, Map.get(new_counts, identity, 0))
    end)
  end

  defp frequencies(directives), do: Enum.frequencies_by(directives, &identity/1)

  defp identity(directive) do
    {directive.file, directive.scope, directive.tokens, directive.reason}
  end

  defp changed_directive?(directive, changed_ranges, side) do
    changed_ranges
    |> Map.get(directive.file, [])
    |> Enum.map(&Range.normalize/1)
    |> Enum.any?(&Range.contains_line?(&1, side, directive.line))
  end

  defp changed_source_files(changed_ranges) do
    changed_ranges
    |> Map.keys()
    |> Enum.filter(&(Path.extname(&1) in [".ex", ".exs"]))
    |> Enum.sort()
  end

  defp sort_directives(directives), do: Enum.sort_by(directives, &{&1.file, &1.line, &1.scope})
end
