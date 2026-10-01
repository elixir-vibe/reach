defmodule Reach.Smell.Checks.DualKeyAccess do
  @moduledoc "Detects mixed atom/string key access on the same map."

  use Reach.Smell.Check
  alias Reach.Smell.ExecutionContext

  defp findings(function) do
    nodes = function |> ExecutionContext.annotate() |> IR.all_nodes()

    nodes
    |> Enum.flat_map(&key_access/1)
    |> Enum.group_by(fn access -> {access.binding, access.key} end)
    |> Enum.flat_map(fn {{_binding, key}, [first | _] = accesses} ->
      key_types = accesses |> Enum.map(& &1.key_type) |> MapSet.new()

      if MapSet.subset?(MapSet.new([:atom, :string]), key_types) do
        [dual_key_finding(first.variable, key, accesses)]
      else
        []
      end
    end)
  end

  defp key_access(%{type: :call, meta: %{module: module, function: :get, arity: arity}} = node)
       when module in [Access, Map] and arity in [2, 3] do
    case node.children do
      [%{type: :var, meta: %{name: variable} = meta}, %{type: :literal, meta: %{value: key}} | _]
      when is_atom(key) or is_binary(key) ->
        [
          %{
            variable: variable,
            binding: meta[:smell_binding],
            key: key_name(key),
            key_type: key_type(key),
            location: Helpers.location(node)
          }
        ]

      _ ->
        []
    end
  end

  defp key_access(_node), do: []

  defp dual_key_finding(variable, key, accesses) do
    locations = accesses |> Enum.map(& &1.location) |> Enum.uniq()

    Finding.new(
      kind: :dual_key_access,
      message:
        "#{variable} is accessed with both atom and string key #{inspect(key)}; normalize the map once or use a struct/contract",
      location: List.first(locations),
      evidence: locations
    )
  end

  defp key_name(key) when is_binary(key), do: key
  defp key_name(key) when is_atom(key), do: Atom.to_string(key)

  defp key_type(key) when is_binary(key), do: :string
  defp key_type(key) when is_atom(key), do: :atom
end
