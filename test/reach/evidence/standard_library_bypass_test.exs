defmodule Reach.Evidence.StandardLibraryBypassTest do
  use ExUnit.Case, async: true

  alias Reach.Evidence.StandardLibraryBypass

  test "exposes evidence metadata" do
    assert StandardLibraryBypass.family() == :stdlib
    assert :manual_frequencies in StandardLibraryBypass.kinds()
  end

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

  test "collects reduce based frequencies evidence" do
    ast =
      Code.string_to_quoted!("""
      Enum.reduce(items, %{}, fn item, acc ->
        Map.update(acc, item, 1, &(&1 + 1))
      end)
      """)

    assert [%{kind: :manual_frequencies, replacement: "Enum.frequencies/1"}] =
             StandardLibraryBypass.collect_ast(ast)
  end

  test "collects reduce based frequencies_by evidence" do
    ast =
      Code.string_to_quoted!("""
      Enum.reduce(users, %{}, fn user, acc ->
        count = Map.get(acc, user.role, 0)
        Map.put(acc, user.role, count + 1)
      end)
      """)

    assert [%{kind: :manual_frequencies_by, replacement: "Enum.frequencies_by/2"}] =
             StandardLibraryBypass.collect_ast(ast)
  end

  test "collects reduce based flat_map evidence" do
    ast =
      Code.string_to_quoted!("""
      Enum.reduce(items, [], fn item, acc ->
        acc ++ expand(item)
      end)
      """)

    assert [%{kind: :manual_flat_map_reduce, replacement: "Enum.flat_map/2"}] =
             StandardLibraryBypass.collect_ast(ast)
  end

  test "collects reduce reverse chunk followed by reverse evidence" do
    ast =
      Code.string_to_quoted!("""
      items
      |> Enum.reduce([], fn item, acc ->
        Enum.reverse(expand(item), acc)
      end)
      |> Enum.reverse()
      """)

    assert [%{kind: :manual_flat_map_prepend_reverse, replacement: "Enum.flat_map/2"}] =
             StandardLibraryBypass.collect_ast(ast)
  end

  test "does not flag unsafe chunk prepend followed by reverse" do
    ast =
      Code.string_to_quoted!("""
      items
      |> Enum.reduce([], fn item, acc ->
        expand(item) ++ acc
      end)
      |> Enum.reverse()
      """)

    assert [] = StandardLibraryBypass.collect_ast(ast)
  end

  test "collects fetch bang followed by put evidence" do
    ast =
      Code.string_to_quoted!("""
      current = Map.fetch!(state, :count)
      Map.put(state, :count, current + 1)
      """)

    assert [%{kind: :manual_map_update_bang, replacement: "Map.update!/3"}] =
             StandardLibraryBypass.collect_ast(ast)
  end

  test "collects inline fetch bang followed by put evidence" do
    ast = Code.string_to_quoted!("Map.put(state, :count, Map.fetch!(state, :count) + 1)")

    assert [%{kind: :manual_map_update_bang, replacement: "Map.update!/3"}] =
             StandardLibraryBypass.collect_ast(ast)
  end

  test "does not flag reduce when callback has extra payload logic" do
    ast =
      Code.string_to_quoted!("""
      Enum.reduce(items, %{}, fn item, acc ->
        Map.update(acc, item, [item], &[item | &1])
      end)
      """)

    assert [] = StandardLibraryBypass.collect_ast(ast)
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
