defmodule Reach.Evidence.DSLGuardTest do
  use ExUnit.Case, async: true

  alias Reach.Evidence.DSLGuard

  test "filters generic evidence inside plugin-reinterpreted source ranges" do
    {:ok, ast} =
      Code.string_to_quoted("""
      from p in Post,
        where: p.id in ids
      transform(value)
      """)

    evidence = [
      %{kind: :inside, meta: [line: 2]},
      %{kind: :outside, meta: [line: 3]}
    ]

    assert [%{kind: :outside}] = DSLGuard.filter(evidence, ast, [Reach.Plugins.Ecto])
  end

  test "uses columns to preserve same-line evidence outside a nested DSL call" do
    ast = Sourceror.parse_string!("pair(Enum.at(items, 0), Ash.Expr.expr(left <> right))")

    evidence = [
      %{kind: :outside, meta: [line: 1, column: 6]},
      %{kind: :inside, meta: [line: 1, column: 45]}
    ]

    assert [%{kind: :outside}] = DSLGuard.filter(evidence, ast, [Reach.Plugins.Ash])
  end

  test "filters generic evidence inside configured source ranges" do
    ast = Sourceror.parse_string!("MyDSL.expr(value)")
    evidence = [%{kind: :inside, location: %{line: 1}}]

    assert [] =
             DSLGuard.filter(evidence, ast, [], smells: [dsl_macros: [{MyDSL, :expr, 1}]])
  end
end
