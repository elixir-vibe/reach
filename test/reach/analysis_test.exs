defmodule Reach.AnalysisTest do
  use ExUnit.Case, async: true

  alias Reach.Analysis
  alias Reach.IR.Node

  test "expected effect boundary ignores Erlang module atoms" do
    node = %Node{
      id: "fun",
      type: :function_def,
      meta: %{module: :zigler, name: :run, arity: 0},
      source_span: nil,
      children: []
    }

    refute Analysis.expected_effect_boundary?(node)
  end
end
