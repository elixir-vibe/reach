defmodule Reach.Smell.Checks.DefaultDrift do
  @moduledoc "Detects conflicting explicit defaults for one map-contract key."

  @behaviour Reach.Smell.Check

  alias Reach.Evidence.MapContract
  alias Reach.Smell.{Finding, Helpers}

  @impl true
  def kinds, do: [:default_drift]

  @impl true
  def run(project) do
    parent_index = parent_index(project.nodes)

    project
    |> MapContract.collect_key_accesses()
    |> Enum.flat_map(&access_default/1)
    |> Enum.reject(fn {access, _default} -> access.map_origins == [] end)
    |> Enum.group_by(fn {access, _default} -> {access.map_origins, access.logical_key} end)
    |> Enum.flat_map(&finding_for_group(&1, parent_index))
  end

  defp access_default(%{default_node: %{type: :literal, meta: %{value: value}}} = access) do
    [{access, value}]
  end

  defp access_default(_access), do: []

  defp finding_for_group({_contract_key, accesses_and_defaults}, parent_index) do
    defaults =
      accesses_and_defaults
      |> Enum.map(&elem(&1, 1))
      |> Enum.uniq()
      |> Enum.sort_by(&:erlang.term_to_binary/1)

    accesses =
      accesses_and_defaults
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort_by(&Helpers.source_sort_key(&1.node))

    if length(defaults) >= 2 and
         not mutually_exclusive_defaults?(accesses_and_defaults, parent_index) do
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

  defp mutually_exclusive_defaults?(accesses_and_defaults, parent_index) do
    accesses = Enum.map(accesses_and_defaults, &elem(&1, 0))
    functions = accesses |> Enum.map(& &1.function) |> Enum.uniq()
    contexts = Enum.map(accesses, &clause_context(&1.node.id, parent_index))

    length(functions) == 1 and Enum.all?(contexts, & &1) and
      contexts |> Enum.uniq() |> length() >= 2 and
      accesses_and_defaults
      |> Enum.group_by(
        fn {access, _default} -> clause_context(access.node.id, parent_index) end,
        &elem(&1, 1)
      )
      |> Enum.all?(fn {_context, defaults} -> length(Enum.uniq(defaults)) == 1 end)
  end

  defp parent_index(nodes) do
    nodes
    |> Map.values()
    |> Enum.reduce(%{}, fn node, index ->
      Enum.reduce(node.children, index, &Map.put(&2, &1.id, node))
    end)
  end

  defp clause_context(node_id, parent_index) do
    case parent_index[node_id] do
      %{type: :clause, id: id} -> id
      %{id: parent_id} -> clause_context(parent_id, parent_index)
      nil -> nil
    end
  end
end
