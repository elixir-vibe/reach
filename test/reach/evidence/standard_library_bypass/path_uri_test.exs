defmodule Reach.Evidence.StandardLibraryBypass.PathURITest do
  use ExUnit.Case, async: true

  alias Reach.Evidence.StandardLibraryBypass.PathURI

  defp collect(ast), do: PathURI.collect_ast(ast)

  test "collects path and URI split evidence" do
    ast = Code.string_to_quoted!("path |> String.split(\"/\") |> List.last()")
    assert [%{kind: :manual_path_basename}] = collect(ast)

    ast = Code.string_to_quoted!("String.split(query, \"&\")")
    assert [%{kind: :manual_query_parsing}] = collect(ast)
  end

  test "ignores non-path names" do
    ast = Code.string_to_quoted!("slug |> String.split(\"/\") |> List.last()")
    assert [] = collect(ast)
  end
end
