defmodule Reach.Evidence.StandardLibraryBypass.EnumTest do
  use ExUnit.Case, async: true

  alias Reach.Evidence.StandardLibraryBypass.Enum, as: EnumEvidence

  defp collect(ast), do: EnumEvidence.collect_ast(ast)

  test "collects direct and reduce-based flat_map evidence" do
    ast = Code.string_to_quoted!("items |> Enum.map(&expand/1) |> List.flatten()")

    assert [%{kind: :manual_flat_map, confidence: :medium} = evidence] =
             EnumEvidence.collect_ast(ast)

    assert evidence.message =~ "recursive flattening"

    ast = Code.string_to_quoted!("items |> Enum.map(&expand/1) |> Enum.concat()")
    assert [%{kind: :manual_flat_map, confidence: :high}] = EnumEvidence.collect_ast(ast)

    ast =
      Code.string_to_quoted!("Enum.reduce(items, [], fn item, acc -> acc ++ expand(item) end)")

    assert [%{kind: :manual_flat_map_reduce}] = collect(ast)
  end

  test "does not flag reduce append of one-element literal lists as flat_map" do
    ast =
      Code.string_to_quoted!(
        "Enum.reduce(items, [], fn item, acc -> acc ++ [transform(item)] end)"
      )

    assert [] = collect(ast)
  end

  test "collects order-safe prepend reverse flat_map evidence" do
    ast =
      Code.string_to_quoted!("""
      items
      |> Enum.reduce([], fn item, acc -> Enum.reverse(expand(item), acc) end)
      |> Enum.reverse()
      """)

    assert [%{kind: :manual_flat_map_prepend_reverse}] = collect(ast)
  end

  test "collects frequencies evidence" do
    ast =
      Code.string_to_quoted!("""
      Enum.reduce(items, %{}, fn item, acc -> Map.update(acc, item, 1, &(&1 + 1)) end)
      """)

    assert [%{kind: :manual_frequencies}] = collect(ast)
  end
end
