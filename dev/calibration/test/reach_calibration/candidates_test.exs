defmodule ReachCalibration.CandidatesTest do
  use ExUnit.Case, async: true

  alias ReachCalibration.Candidates

  test "deduplicates indexed prefilters for covered smell kinds" do
    kinds = MapSet.new([:dual_key_fallback, :false_collapsing_lookup, :default_drift])

    assert Candidates.patterns(kinds) == ["Map.get(_, _)", "Map.get(_, _, _)"]
  end

  test "uses the guarded-domain prefilter for total-function laundering" do
    assert Candidates.patterns(MapSet.new([:total_function_laundering])) == [
             "_ when _ in [_, _]",
             "defp _(_), do: _"
           ]
  end

  test "uses plugin-owned decoder prefilters for boundary leakage" do
    assert Candidates.patterns(MapSet.new([:decoded_boundary_leakage])) == [
             "Jason.decode!(_)",
             "Jason.decode(_)",
             "Poison.decode!(_)",
             "Poison.decode(_)"
           ]
  end

  test "uses tagged result prefilters for return contract checks" do
    assert Candidates.patterns(MapSet.new([:return_shape_divergence, :nested_return_tag])) == [
             "{:ok, _}",
             "{:ok, {:ok, _}}"
           ]
  end

  test "uses struct declarations to prefilter representation overlap checks" do
    assert Candidates.patterns(MapSet.new([:same_entity_representation])) == ["defstruct _"]
  end

  test "uses fixed map reads to prefilter parameter entropy checks" do
    assert Candidates.patterns(MapSet.new([:parameter_shape_entropy])) == ["Map.get(_, _)"]
  end

  test "uses nil-argument prefilters for nil guard checks" do
    patterns = Candidates.patterns(MapSet.new([:nil_parameter_without_guard]))

    assert MapSet.new(patterns) ==
             MapSet.new([
               "_(nil)",
               "_(nil, _)",
               "_(_, nil)",
               "_(nil, _, _)",
               "_(_, nil, _)",
               "_(_, _, nil)"
             ])
  end

  test "falls back to package-version selection when any kind lacks a safe prefilter" do
    assert Candidates.patterns(MapSet.new([:dual_key_fallback, :unmapped_kind])) == :all
    assert Candidates.patterns(nil) == :all
  end
end
