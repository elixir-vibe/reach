defmodule Reach.ASTTest do
  use ExUnit.Case, async: true

  test "fetches ordinary and Sourceror-wrapped keyword values" do
    assert {:ok, :ok} = Reach.AST.keyword_fetch([do: :ok], :do)

    {:ok, ast} = Sourceror.parse_string("sample(do: :ok)")
    {_module, _function, [wrapped_keyword]} = Reach.AST.call(ast)

    assert {:ok, wrapped_value} = Reach.AST.keyword_fetch(wrapped_keyword, :do)
    assert {:__block__, _meta, [:ok]} = wrapped_value
    assert wrapped_value == Reach.AST.keyword_value(wrapped_keyword, :do)
  end

  test "extracts static module and function identities" do
    assert {:ok, MyApp.Parser} = Reach.AST.module_name({:__aliases__, [], [:MyApp, :Parser]})
    assert :error = Reach.AST.module_name({:__aliases__, [], [:MyApp, {:dynamic, [], nil}]})

    assert {:ok, :parse, 2} = Reach.AST.function_identity({:parse, [], [{:x, [], nil}, 1]})

    assert {:ok, :parse, 1} =
             Reach.AST.function_identity(
               {:when, [], [{:parse, [], [{:x, [], nil}]}, {:is_binary, [], [{:x, [], nil}]}]}
             )
  end

  test "returns missing values without raising" do
    assert :error = Reach.AST.keyword_fetch([], :do)
    assert is_nil(Reach.AST.keyword_value([], :do))
  end
end
