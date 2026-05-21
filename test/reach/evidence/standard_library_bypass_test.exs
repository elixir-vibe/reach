defmodule Reach.Evidence.StandardLibraryBypassTest do
  use ExUnit.Case, async: true

  alias Reach.Evidence.StandardLibraryBypass

  test "collects manual path basename evidence" do
    ast = Code.string_to_quoted!("path |> String.split(\"/\") |> List.last()")

    assert [%{kind: :manual_path_basename, replacement: "Path.basename/1"}] =
             StandardLibraryBypass.collect_ast(ast)
  end

  test "collects manual URL query splitting evidence" do
    ast = Code.string_to_quoted!("String.split(query, \"&\")")

    assert [%{kind: :manual_query_parsing, replacement: "URI.decode_query/1"}] =
             StandardLibraryBypass.collect_ast(ast)
  end

  test "collects map followed by flatten evidence" do
    ast = Code.string_to_quoted!("items |> Enum.map(&expand/1) |> List.flatten()")

    assert [%{kind: :manual_flat_map, replacement: "Enum.flat_map/2"}] =
             StandardLibraryBypass.collect_ast(ast)
  end

  test "collects paired Map.get and Map.put update evidence" do
    ast =
      Code.string_to_quoted!("""
      case Map.get(groups, key) do
        nil -> Map.put(groups, key, [value])
        values -> Map.put(groups, key, [value | values])
      end
      """)

    assert [%{kind: :manual_map_update, replacement: "Map.update/4"}] =
             StandardLibraryBypass.collect_ast(ast)
  end

  test "collects Map.has_key? conditional update evidence" do
    ast =
      Code.string_to_quoted!("""
      if Map.has_key?(counts, key) do
        Map.put(counts, key, count + 1)
      else
        Map.put(counts, key, 1)
      end
      """)

    assert [%{kind: :manual_map_update, replacement: "Map.update/4"}] =
             StandardLibraryBypass.collect_ast(ast)
  end

  test "does not flag unrelated Map.put branches" do
    ast =
      Code.string_to_quoted!("""
      case Map.get(groups, key) do
        nil -> Map.put(other, key, [value])
        values -> Map.put(groups, other_key, [value | values])
      end
      """)

    assert [] = StandardLibraryBypass.collect_ast(ast)
  end

  test "ignores slash splits for non-path variables" do
    ast = Code.string_to_quoted!("slug |> String.split(\"/\") |> List.last()")

    assert [] = StandardLibraryBypass.collect_ast(ast)
  end
end
