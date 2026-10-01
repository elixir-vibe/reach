defmodule Reach.Frontend.GuardedCallbackTest do
  use ExUnit.Case, async: true

  alias Reach.IR
  alias Reach.IR.Node

  test "all guarded anonymous parameters remain definitions rather than guards" do
    [function] =
      IR.from_string!(
        "fn {:ok, addresses}, {:ok, collected} when is_list(addresses) -> collected ++ addresses end"
      )

    assert %Node{
             type: :fn,
             children: [
               %Node{
                 type: :clause,
                 meta: %{arity: 2},
                 children: [first, second, guard, body]
               }
             ]
           } = function

    assert first.type == :tuple
    assert second.type == :tuple

    assert Enum.any?(
             IR.all_nodes(first),
             &match?(%Node{type: :var, meta: %{name: :addresses, binding_role: :definition}}, &1)
           )

    assert Enum.any?(
             IR.all_nodes(second),
             &match?(%Node{type: :var, meta: %{name: :collected, binding_role: :definition}}, &1)
           )

    assert %Node{type: :guard, children: [%Node{type: :call, meta: %{function: :is_list}}]} =
             guard

    assert %Node{type: :binary_op, meta: %{operator: :++}} = body
  end

  test "a single guarded pattern defines its binding and retains one guard" do
    [expression] = IR.from_string!("case input do value when is_integer(value) -> value end")

    [%Node{type: :clause, children: [pattern, guard, result]}] =
      Enum.filter(expression.children, &(&1.type == :clause))

    assert %Node{type: :var, meta: %{name: :value, binding_role: :definition}} = pattern

    assert %Node{type: :guard, children: [%Node{type: :call, meta: %{function: :is_integer}}]} =
             guard

    assert %Node{type: :var, meta: %{name: :value}} = result
  end

  test "alternative when guards stay a guard expression rather than extra parameters" do
    [function] =
      IR.from_string!("fn value when is_integer(value) when is_float(value) -> value end")

    assert [%Node{meta: %{arity: 1}, children: [pattern, guard, _body]}] = function.children
    assert %Node{type: :var, meta: %{name: :value, binding_role: :definition}} = pattern
    assert guard.type == :guard

    assert Enum.any?(
             IR.all_nodes(guard),
             &match?(%Node{type: :call, meta: %{function: :is_integer}}, &1)
           )

    assert Enum.any?(
             IR.all_nodes(guard),
             &match?(%Node{type: :call, meta: %{function: :is_float}}, &1)
           )
  end
end
