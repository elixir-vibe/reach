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

  test "ignores slash splits for non-path variables" do
    ast = Code.string_to_quoted!("slug |> String.split(\"/\") |> List.last()")

    assert [] = StandardLibraryBypass.collect_ast(ast)
  end
end
