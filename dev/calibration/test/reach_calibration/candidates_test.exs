defmodule ReachCalibration.CandidatesTest do
  use ExUnit.Case, async: true

  alias ReachCalibration.Candidates

  test "deduplicates indexed prefilters for covered smell kinds" do
    kinds = MapSet.new([:dual_key_fallback, :false_collapsing_lookup, :default_drift])

    assert Candidates.patterns(kinds) == ["Map.get(_, _)", "Map.get(_, _, _)"]
  end

  test "falls back to package-version selection when any kind lacks a safe prefilter" do
    assert Candidates.patterns(MapSet.new([:dual_key_fallback, :unmapped_kind])) == :all
    assert Candidates.patterns(nil) == :all
  end
end
