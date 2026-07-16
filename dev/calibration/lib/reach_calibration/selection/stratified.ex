defmodule ReachCalibration.Selection.Stratified do
  @moduledoc "Deterministic round-robin selection across indexed candidate patterns."

  @spec select([map()], pos_integer(), String.t()) :: [map()]
  def select(candidates, limit, seed) do
    candidates
    |> candidate_groups(seed)
    |> select_rounds(MapSet.new(), [], limit)
    |> Enum.reverse()
  end

  defp candidate_groups(candidates, seed) do
    candidates
    |> Enum.flat_map(fn candidate ->
      candidate
      |> Map.get("candidate_patterns", ["all"])
      |> Enum.map(&{&1, candidate})
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {pattern, group} ->
      Enum.sort_by(group, &selection_key(&1, pattern, seed))
    end)
  end

  defp select_rounds(_groups, _seen, selected, limit) when length(selected) >= limit,
    do: Enum.take(selected, limit)

  defp select_rounds([], _seen, selected, _limit), do: selected

  defp select_rounds(groups, seen, selected, limit) do
    {round, remaining} =
      Enum.reduce(groups, {[], []}, fn
        [candidate | rest], {round, remaining} ->
          {[candidate | round], if(rest == [], do: remaining, else: [rest | remaining])}

        [], acc ->
          acc
      end)

    {seen, selected} =
      round
      |> Enum.reverse()
      |> Enum.reduce({seen, selected}, fn candidate, {seen, selected} ->
        identity = identity(candidate)

        if MapSet.member?(seen, identity) or length(selected) >= limit do
          {seen, selected}
        else
          {MapSet.put(seen, identity), [candidate | selected]}
        end
      end)

    select_rounds(Enum.reverse(remaining), seen, selected, limit)
  end

  defp selection_key(candidate, pattern, seed) do
    payload = [seed, pattern | Tuple.to_list(identity(candidate))] |> Enum.join("\0")
    :crypto.hash(:sha256, payload)
  end

  defp identity(candidate) do
    {candidate["ecosystem"], candidate["package_name"], candidate["version"]}
  end
end
