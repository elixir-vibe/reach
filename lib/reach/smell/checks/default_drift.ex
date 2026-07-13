defmodule Reach.Smell.Checks.DefaultDrift do
  @moduledoc "Detects conflicting explicit defaults for one map-contract key."

  @behaviour Reach.Smell.Check

  alias Reach.Evidence.MapContract
  alias Reach.Smell.{Finding, Helpers}

  @impl true
  def kinds, do: [:default_drift]

  @impl true
  def run(project) do
    project
    |> MapContract.collect_key_accesses()
    |> Enum.flat_map(&access_default/1)
    |> Enum.reject(fn {access, _default} -> access.map_origins == [] end)
    |> Enum.group_by(fn {access, _default} -> {access.map_origins, access.logical_key} end)
    |> Enum.flat_map(&finding_for_group/1)
  end

  defp access_default(%{default_node: %{type: :literal, meta: %{value: value}}} = access) do
    [{access, value}]
  end

  defp access_default(_access), do: []

  defp finding_for_group({_contract_key, accesses_and_defaults}) do
    defaults = accesses_and_defaults |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()

    if length(defaults) >= 2 do
      accesses = Enum.map(accesses_and_defaults, &elem(&1, 0))
      first = List.first(accesses)

      [
        Finding.new(
          kind: :default_drift,
          message:
            "map key #{inspect(first.key_label)} uses conflicting defaults #{Enum.map_join(defaults, ", ", &inspect/1)}; define the contract default once",
          location: Helpers.location(first.node),
          evidence: Enum.map(accesses, &Helpers.location(&1.node)) |> Enum.uniq(),
          keys: [first.key_label],
          confidence: :high
        )
      ]
    else
      []
    end
  end
end
