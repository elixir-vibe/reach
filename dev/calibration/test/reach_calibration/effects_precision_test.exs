defmodule ReachCalibration.EffectsPrecisionTest do
  use ExUnit.Case, async: false

  alias Reach.Map.Analysis

  @max_unknown_ratio 0.10

  @tag timeout: 120_000
  test "Reach's runtime effect unknown ratio stays within its precision budget" do
    files = Path.wildcard("../../lib/**/*.{ex,exs}")
    project = Reach.Project.from_sources(files, plugins: Reach.Plugin.detect())
    summary = Analysis.section_data(project, :effects, %{top: 1}, nil)

    unknown_count =
      summary.distribution
      |> Enum.find(&(&1.effect == :unknown))
      |> case do
        nil -> 0
        row -> row.count
      end

    unknown_ratio = unknown_count / max(summary.total_calls, 1)

    assert unknown_ratio <= @max_unknown_ratio,
           "expected unknown runtime effects to stay at or below #{percent(@max_unknown_ratio)}, " <>
             "got #{percent(unknown_ratio)} (#{unknown_count}/#{summary.total_calls})"
  end

  defp percent(ratio), do: :erlang.float_to_binary(ratio * 100, decimals: 2) <> "%"
end
