defmodule Reach.Evidence.ASTTest do
  use ExUnit.Case, async: true

  alias Reach.Evidence.AST

  test "collect walks AST and returns reversed evidence" do
    ast =
      Code.string_to_quoted!("""
      IO.inspect(:one)
      IO.inspect(:two)
      """)

    assert [line: 1] =
             ast
             |> AST.collect(fn
               {{:., meta, [{:__aliases__, _, [:IO]}, :inspect]}, _, _args}, acc -> [meta | acc]
               _node, acc -> acc
             end)
             |> hd()
  end

  test "reduce walks AST with a custom accumulator" do
    ast =
      Code.string_to_quoted!("""
      IO.inspect(:one)
      IO.inspect(:two)
      """)

    assert 2 ==
             AST.reduce(ast, 0, fn node, count ->
               if AST.remote_call?(node, IO, :inspect), do: count + 1, else: count
             end)
  end

  test "contains and count use predicates" do
    ast = Code.string_to_quoted!(~S[String.replace(name, "-", "_")])

    assert AST.contains?(ast, &AST.remote_call?(&1, String, :replace))
    assert AST.count(ast, &AST.remote_call?(&1, String, :replace)) == 1
  end

  test "matches local, remote, and Erlang calls" do
    local = Code.string_to_quoted!("json_safe(value)")
    remote = Code.string_to_quoted!("Map.from_struct(value)")
    erlang = Code.string_to_quoted!(":json.encode(value)")

    assert AST.call?(local, {:__local__, :json_safe})
    assert AST.call?(remote, {Map, :from_struct})
    assert AST.call?(erlang, {:erlang, :json, :encode})
  end

  test "call descriptor tolerates dynamic aliases" do
    ast = Code.string_to_quoted!("__MODULE__.Engine.render(value)")

    assert {:ok, %{module: nil, function: :render, arity: 1}} = AST.call_descriptor(ast)
  end

  test "compares and finds AST references" do
    ast = Code.string_to_quoted!("value + 1")
    expected = Code.string_to_quoted!("value")

    assert AST.references?(ast, expected)
    assert AST.same_ast?(expected, Code.string_to_quoted!("value"))
  end
end
