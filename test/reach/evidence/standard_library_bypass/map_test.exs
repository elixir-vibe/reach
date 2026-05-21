defmodule Reach.Evidence.StandardLibraryBypass.MapTest do
  use ExUnit.Case, async: true

  alias Reach.Evidence.StandardLibraryBypass.Map, as: MapEvidence

  defp collect(ast), do: MapEvidence.collect_ast(ast)

  test "collects paired Map.get and Map.put update evidence" do
    ast =
      Code.string_to_quoted!("""
      case Map.get(groups, key) do
        nil -> Map.put(groups, key, [value])
        values -> Map.put(groups, key, [value | values])
      end
      """)

    assert [%{kind: :manual_map_update}] = collect(ast)
  end

  test "collects fetch bang followed by put evidence" do
    ast =
      Code.string_to_quoted!("""
      current = Map.fetch!(state, :count)
      Map.put(state, :count, current + 1)
      """)

    assert [%{kind: :manual_map_update_bang}] = collect(ast)
  end
end
