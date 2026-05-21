defmodule Reach.Evidence.StandardLibraryBypass.MapTest do
  use ExUnit.Case, async: true

  alias Reach.Evidence.StandardLibraryBypass.Map, as: MapEvidence

  defp collect(ast) do
    {_ast, evidence} =
      Macro.prewalk(ast, [], fn node, acc -> {node, MapEvidence.collect_node(node, acc)} end)

    Enum.reverse(evidence)
  end

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
