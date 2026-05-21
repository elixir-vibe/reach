defmodule Reach.Plugins.Jason.Evidence.HandRolledEncoderTest do
  use ExUnit.Case, async: true

  alias Reach.Plugins.Jason.Evidence.HandRolledEncoder

  test "exposes evidence metadata" do
    assert HandRolledEncoder.family() == :jason
    assert :hand_rolled_json_sanitizer in HandRolledEncoder.kinds()
  end

  test "collects recursive json_safe evidence" do
    ast =
      Code.string_to_quoted!("""
      def json_safe(%_{} = value), do: value |> Map.from_struct() |> json_safe()
      def json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
      """)

    assert [%{kind: :hand_rolled_json_sanitizer, replacement: "Jason.Encoder"} | _] =
             HandRolledEncoder.collect_ast(ast)
  end

  test "collects manual JSON pretty-printer evidence" do
    ast =
      Code.string_to_quoted!("""
      defp indent_json(value) do
        value
        |> to_string()
        |> String.replace("\\\"", "\\\\\\\"")
      end
      """)

    assert [%{kind: :hand_rolled_json_encoder, replacement: "Jason.encode/2"}] =
             HandRolledEncoder.collect_ast(ast)
  end

  test "ignores stdlib JSON wrappers" do
    ast =
      Code.string_to_quoted!("""
      def encode!(data) do
        data
        |> :json.encode()
        |> IO.iodata_to_binary()
      end
      """)

    assert [] = HandRolledEncoder.collect_ast(ast)
  end

  test "collects Jason encoders that delegate to direct to_map projections" do
    ast =
      Code.string_to_quoted!("""
      defmodule Example do
        defimpl Jason.Encoder, for: Example do
          def encode(value, opts), do: Jason.Encode.map(Example.to_map(value), opts)
        end

        def to_map(value), do: Map.from_struct(value)
      end
      """)

    assert [%{kind: :manual_jason_encoder_map, replacement: "@derive Jason.Encoder"}] =
             HandRolledEncoder.collect_ast(ast)
  end

  test "ignores Jason encoders backed by non-trivial to_map helpers" do
    ast =
      Code.string_to_quoted!("""
      defmodule Example do
        defimpl Jason.Encoder, for: Example do
          def encode(value, opts), do: Jason.Encode.map(Example.to_map(value), opts)
        end

        def to_map(value), do: %{name: value.name}
      end
      """)

    assert [] = HandRolledEncoder.collect_ast(ast)
  end

  test "ignores unrelated to_map helpers" do
    ast =
      Code.string_to_quoted!("""
      def to_map(value), do: %{value: value}
      """)

    assert [] = HandRolledEncoder.collect_ast(ast)
  end
end
