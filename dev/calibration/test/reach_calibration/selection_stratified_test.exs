defmodule ReachCalibration.Selection.StratifiedTest do
  use ExUnit.Case, async: true

  alias ReachCalibration.Selection.Stratified

  test "selects candidates reproducibly from a stable seed" do
    candidates = Enum.map(1..20, &candidate(&1, ["Map.get(_, _)"]))

    assert Stratified.select(candidates, 8, "seed-a") ==
             Stratified.select(Enum.reverse(candidates), 8, "seed-a")

    refute Stratified.select(candidates, 8, "seed-a") ==
             Stratified.select(candidates, 8, "seed-b")
  end

  test "round-robins across candidate pattern strata" do
    candidates = [
      candidate(1, ["Map.get(_, _)"]),
      candidate(2, ["Map.get(_, _)"]),
      candidate(3, ["Atom.to_string(_)"]),
      candidate(4, ["Atom.to_string(_)"])
    ]

    selected = Stratified.select(candidates, 2, "stable")
    patterns = selected |> Enum.flat_map(& &1["candidate_patterns"]) |> MapSet.new()

    assert patterns == MapSet.new(["Map.get(_, _)", "Atom.to_string(_)"])
  end

  defp candidate(index, patterns) do
    %{
      "ecosystem" => "hex",
      "package_name" => "package_#{index}",
      "version" => "1.0.0",
      "candidate_patterns" => patterns
    }
  end
end
