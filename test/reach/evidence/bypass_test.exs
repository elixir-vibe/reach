defmodule Reach.Evidence.BypassTest do
  use ExUnit.Case, async: true

  alias Reach.Evidence.{Bypass, StandardLibraryBypass}
  alias Reach.Plugins.Jason.Evidence.HandRolledEncoder

  test "normalizes standard-library bypass evidence" do
    ast = Sourceror.parse_string!("Enum.map(items, fun) |> List.flatten()")

    assert [fact] = StandardLibraryBypass.collect_ast(ast)
    assert fact.data.category == :capability_bypass
    assert fact.data.provider == :elixir_standard_library
    assert fact.data.capability == fact.kind
    assert fact.data.origin == :stdlib_pattern
    assert Bypass.fact?(fact)
  end

  test "normalizes dependency-specific plugin evidence" do
    ast =
      Sourceror.parse_string!("""
      def encode_json(value) do
        value
        |> inspect()
        |> String.replace("<", "\\u003c")
      end
      """)

    assert [fact] = HandRolledEncoder.collect_ast(ast)
    assert fact.data.category == :capability_bypass
    assert fact.data.provider == Jason
    assert fact.data.capability == :json_encoding
    assert fact.data.origin == :plugin_pattern
    assert Bypass.fact?(fact)
  end
end
