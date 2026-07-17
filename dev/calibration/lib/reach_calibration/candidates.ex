defmodule ReachCalibration.Candidates do
  @moduledoc "Indexed Exograph prefilters for high-confidence Reach smell calibration."

  @patterns %{
    dual_key_fallback: ["Map.get(_, _)"],
    false_collapsing_lookup: ["Map.get(_, _)"],
    key_normalization_collision: ["Atom.to_string(_)"],
    key_representation_churn: ["Atom.to_string(_)"],
    broad_map_contract: ["map()"],
    broad_callback_map_contract: ["@callback _"],
    mixed_schema_key_representation: ["Map.get(_, _)"],
    schema_undeclared_key_access: ["Map.get(_, _)"],
    schema_key_representation_mismatch: ["Map.get(_, _)"],
    required_schema_key_default: ["Map.get(_, _, _)"],
    default_drift: ["Map.get(_, _, _)"],
    decoded_boundary_leakage: [
      "Jason.decode!(_)",
      "Jason.decode(_)",
      "Poison.decode!(_)",
      "Poison.decode(_)"
    ],
    total_function_laundering: ["_ when _ in [_, _]", "defp _(_), do: _"]
  }

  @spec supported_kinds() :: [atom()]
  def supported_kinds, do: @patterns |> Map.keys() |> Enum.sort()

  @spec patterns(MapSet.t(atom()) | nil) :: :all | [String.t()]
  def patterns(nil), do: :all

  def patterns(kinds) do
    if Enum.all?(kinds, &Map.has_key?(@patterns, &1)) do
      kinds
      |> Enum.flat_map(&Map.fetch!(@patterns, &1))
      |> Enum.uniq()
      |> Enum.sort()
    else
      :all
    end
  end
end
