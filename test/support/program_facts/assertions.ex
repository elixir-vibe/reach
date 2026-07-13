defmodule Reach.Test.ProgramFacts.Assertions do
  @moduledoc false

  import ExUnit.Assertions

  alias Mix.Tasks.Reach.Check, as: ReachCheck
  alias Reach.Test.ProgramFacts.{API, CLI, Normalize}

  def assert_modules_discovered(program) do
    expected = Normalize.modules(program.facts.modules)
    actual = API.modules(program)

    assert_subset(expected, actual, "generated modules")
  end

  def assert_call_edges_discovered(program) do
    expected = Normalize.call_edges(program.facts.call_edges)
    actual = API.call_edges(program)

    missing = Enum.reject(expected, &edge_discovered?(&1, actual))

    assert missing == [],
           "expected generated call edges to be discovered, missing: #{inspect(missing)}"
  end

  def assert_effects_discovered(program) do
    expected = MapSet.new(program.facts.effects)
    actual = API.effects(program)

    assert_subset(expected, actual, "generated effects")
  end

  def assert_architecture_policy(program) do
    data = architecture_result(program)

    case expected_architecture_violation(program) do
      nil ->
        assert %{"status" => "ok", "violations" => []} = data

      expected_type ->
        assert %{"status" => "failed", "violations" => violations} = data
        assert Enum.any?(violations, &match?(%{"type" => ^expected_type}, &1))
    end
  end

  def assert_data_flow_visible(program) do
    variables = API.variable_names(program)
    data_labels = API.data_edge_labels(program)

    Enum.each(program.facts.data_flows, fn flow ->
      expected_variables = flow |> Map.get(:variable_names, []) |> MapSet.new()

      assert_subset(expected_variables, variables, "generated data-flow variables")

      assert MapSet.disjoint?(expected_variables, data_labels) == false,
             "expected at least one generated variable to produce a data edge"

      assert_flow_endpoint_visible(program, flow.to)
    end)
  end

  def assert_branches_visible(program) do
    summary = API.branch_summary(program)

    Enum.each(program.facts.branches, fn branch ->
      assert_branch_construct_visible(branch, summary)
      assert_branch_clauses_visible(branch, summary)
      assert_branch_calls_visible(branch, program)
    end)
  end

  def assert_syntax_visible(program) do
    types = API.node_types(program)

    case program.metadata.policy do
      :guard_clause ->
        assert_node_type(types, :guard)
        assert_branches_visible(program)

      :try_rescue_after ->
        assert_node_type(types, :try)
        assert_node_type(types, :rescue)
        assert_node_type(types, :after)
        assert_branches_visible(program)

      :receive_message ->
        assert_node_type(types, :receive)
        assert_branches_visible(program)

      :comprehension ->
        assert_node_type(types, :comprehension)
        assert_node_type(types, :generator)
        assert_data_flow_visible(program)

      :struct_update ->
        assert_node_type(types, :struct)
        assert_node_type(types, :map)
        assert_data_flow_visible(program)

      :default_arguments ->
        assert_function_defs_visible(program)
    end
  end

  defp assert_subset(expected, actual, label) do
    missing = MapSet.difference(expected, actual)

    assert MapSet.size(missing) == 0,
           "expected #{label} to be discovered, missing: #{inspect(missing)}"
  end

  defp assert_branch_construct_visible(%{kind: kind}, summary)
       when kind in [:if, :case, :cond, :with] do
    assert Enum.any?(summary.case_nodes, &case_node_matches?(&1, kind)),
           "expected generated #{kind} branch construct to be visible"
  end

  defp assert_branch_construct_visible(%{kind: :anonymous_fn}, summary) do
    assert [_ | _] = summary.fn_nodes
  end

  defp assert_branch_construct_visible(%{kind: :multi_clause_function}, summary) do
    assert function_clause_count(summary) >= 2,
           "expected generated multi-clause function dispatch to be visible"
  end

  defp assert_branch_construct_visible(%{kind: :guard}, summary) do
    assert function_clause_count(summary) >= 2,
           "expected generated guard clauses to be visible"
  end

  defp assert_branch_construct_visible(%{kind: :try}, summary) do
    assert [_ | _] = summary.clauses
  end

  defp assert_branch_construct_visible(%{kind: :receive}, summary) do
    assert count_clause_kind(summary, [:receive_clause, :timeout_clause]) >= 2,
           "expected generated receive clauses to be visible"
  end

  defp assert_branch_construct_visible(%{kind: :callback}, _summary), do: :ok

  defp assert_branch_clauses_visible(%{kind: :try}, _summary), do: :ok

  defp assert_branch_clauses_visible(%{clauses: expected, kind: kind}, summary) do
    actual = clause_count(summary, kind)

    assert actual >= expected,
           "expected generated #{kind} clauses to be visible, expected at least #{expected}, got #{actual}"
  end

  defp assert_branch_calls_visible(branch, program) do
    branch
    |> Map.get(:calls_by_clause, [])
    |> Enum.each(fn %{call: call} ->
      assert API.call_present?(program, call),
             "expected generated branch call #{inspect(call)} to be visible"
    end)
  end

  defp case_node_matches?(node, :if), do: node.meta[:desugared_from] == :if
  defp case_node_matches?(node, :cond), do: node.meta[:desugared_from] == :cond
  defp case_node_matches?(node, :with), do: node.meta[:desugared_from] == :with
  defp case_node_matches?(node, :case), do: node.meta[:desugared_from] == nil

  defp clause_count(summary, :if), do: count_clause_kind(summary, [:true_branch, :false_branch])
  defp clause_count(summary, :case), do: count_clause_kind(summary, [:case_clause])
  defp clause_count(summary, :cond), do: count_clause_kind(summary, [:cond_clause])
  defp clause_count(summary, :with), do: count_clause_kind(summary, [:with_clause, :else_clause])
  defp clause_count(summary, :anonymous_fn), do: count_clause_kind(summary, [:fn_clause])
  defp clause_count(summary, :multi_clause_function), do: function_clause_count(summary)
  defp clause_count(summary, :callback), do: function_clause_count(summary)
  defp clause_count(summary, :guard), do: function_clause_count(summary)

  defp clause_count(summary, :receive),
    do: count_clause_kind(summary, [:receive_clause, :timeout_clause])

  defp assert_node_type(types, type) do
    assert Map.get(types, type, 0) > 0,
           "expected generated #{type} syntax to be visible, got node types: #{inspect(types)}"
  end

  defp assert_function_defs_visible(program) do
    actual = API.function_defs(program)

    expected =
      program.facts.functions
      |> Enum.map(fn {_module, function, arity} -> {function, arity} end)
      |> MapSet.new()

    assert_subset(expected, actual, "generated function definitions")
  end

  defp count_clause_kind(summary, kinds) do
    Enum.count(summary.clauses, &(&1.meta[:kind] in kinds))
  end

  defp function_clause_count(summary) do
    Enum.count(summary.clauses, &(&1.meta[:kind] == :function_clause))
  end

  defp assert_flow_endpoint_visible(_program, {:return, _function}), do: :ok

  defp assert_flow_endpoint_visible(program, {:arg, {module, function, arity}, _index}) do
    assert API.call_present?(program, {module, function, arity}),
           "expected generated data-flow sink call to be visible"
  end

  defp architecture_result(program) do
    if expected_architecture_violation(program) do
      CLI.run_json_expect_raise(
        program,
        ReachCheck,
        ["--arch"],
        Mix.Error,
        ~r/Architecture policy failed/
      )
    else
      CLI.run_json(program, ReachCheck, ["--arch"])
    end
  end

  defp expected_architecture_violation(program) do
    case program.metadata.policy do
      :layered_valid -> nil
      :forbidden_dependency -> "forbidden_dependency"
      :layer_cycle -> "layer_cycle"
      :public_api_boundary_violation -> "public_api_boundary"
      :internal_boundary_violation -> "internal_boundary"
      :allowed_effect_violation -> "effect_policy"
    end
  end

  defp edge_discovered?({expected_source, expected_target}, actual_edges) do
    Enum.any?(actual_edges, fn {actual_source, actual_target} ->
      function_match?(expected_source, actual_source) and
        function_match?(expected_target, actual_target)
    end)
  end

  defp function_match?(
         {expected_module, expected_function, expected_arity},
         {actual_module, actual_function, actual_arity}
       ) do
    expected_function == actual_function and expected_arity == actual_arity and
      (actual_module == nil or actual_module == expected_module)
  end
end
