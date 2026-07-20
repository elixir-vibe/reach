defmodule Reach.Smell.Checks.LoopAntipattern do
  @moduledoc "Detects O(n²) patterns in loops and recursive functions."

  use Reach.Smell.Check

  defp findings(function) do
    all_nodes = IR.all_nodes(function)

    append_in_loop(all_nodes, function) ++
      concat_in_loop(all_nodes, function) ++
      enum_at_in_loop(all_nodes, function) ++
      list_delete_at_in_loop(all_nodes, function) ++
      manual_min_reduce(all_nodes) ++
      manual_max_reduce(all_nodes) ++
      manual_sum_reduce(all_nodes) ++
      manual_frequencies(all_nodes)
  end

  defp append_in_loop(all_nodes, function) do
    for node <- all_nodes,
        node.type == :binary_op,
        node.meta[:operator] == :++,
        node.source_span,
        quadratic_concat?(node, function),
        accumulator_grows?(node, function) do
      finding(
        :suboptimal,
        "++ growing accumulator inside reduce is O(n²); prepend with [item | acc] and Enum.reverse/1 after",
        node
      )
    end
  end

  defp concat_in_loop(all_nodes, function) do
    for node <- all_nodes,
        node.type == :binary_op,
        node.meta[:operator] == :<>,
        node.source_span,
        quadratic_concat?(node, function) do
      finding(:string_building, "<> inside reduce is O(n²); use iolists or Enum.map_join", node)
    end
  end

  defp enum_at_in_loop(all_nodes, function) do
    for node <- all_nodes,
        node.type == :call,
        node.meta[:module] == Enum,
        node.meta[:function] == :at,
        node.source_span,
        Helpers.inside_loop?(node, function) do
      finding(
        :suboptimal,
        "Enum.at/2 inside loop is O(n) per call; use pattern matching, Enum.with_index/1, or convert to tuple",
        node
      )
    end
  end

  defp list_delete_at_in_loop(all_nodes, function) do
    for node <- all_nodes,
        node.type == :call,
        node.meta[:module] == List,
        node.meta[:function] == :delete_at,
        node.source_span,
        Helpers.inside_loop?(node, function) do
      finding(
        :suboptimal,
        "List.delete_at/2 inside loop is O(n) per call, creating O(n²) cost; use pattern matching or List.delete/2",
        node
      )
    end
  end

  defp quadratic_concat?(node, function) do
    Helpers.inside_accumulator?(node, function) or
      recursive_operand?(node, function)
  end

  defp accumulator_grows?(%{children: [left, _right]}, function) do
    acc_names = accumulator_names(function)

    if acc_names == MapSet.new() do
      true
    else
      left
      |> IR.all_nodes()
      |> Enum.any?(fn n -> n.type == :var and MapSet.member?(acc_names, n.meta[:name]) end)
    end
  end

  defp accumulator_grows?(_, _), do: true

  defp accumulator_names(function) do
    function
    |> IR.all_nodes()
    |> Enum.filter(fn n ->
      n.type == :call and n.meta[:module] in [Enum, Stream] and
        n.meta[:function] in [:reduce, :reduce_while, :scan, :flat_map_reduce, :map_reduce]
    end)
    |> Enum.flat_map(fn call ->
      call.children
      |> Enum.filter(&(&1.type == :fn))
      |> Enum.flat_map(fn fn_node ->
        fn_node.children
        |> Enum.filter(&(&1.type == :clause))
        |> Enum.flat_map(&extract_acc_params/1)
      end)
    end)
    |> MapSet.new()
  end

  defp extract_acc_params(clause) do
    clause.children
    |> Enum.filter(&(&1.meta[:binding_role] == :definition))
    |> Enum.drop(1)
    |> Enum.flat_map(&collect_var_names/1)
  end

  defp collect_var_names(%{type: :var, meta: %{name: name}}), do: [name]

  defp collect_var_names(%{type: :tuple, children: children}),
    do: Enum.flat_map(children, &collect_var_names/1)

  defp collect_var_names(%{type: :list, children: children}),
    do: Enum.flat_map(children, &collect_var_names/1)

  defp collect_var_names(_), do: []

  defp recursive_operand?(%{children: [left, right]}, function) do
    name = function.meta[:name]
    arity = function.meta[:arity]

    contains_self_call?(left, name, arity) or contains_self_call?(right, name, arity)
  end

  defp recursive_operand?(_, _), do: false

  defp contains_self_call?(node, name, arity) do
    IR.all_nodes(node)
    |> Enum.any?(fn n ->
      n.type == :call and n.meta[:function] == name and
        n.meta[:arity] == arity and n.meta[:module] == nil
    end)
  end

  defp manual_min_reduce(all_nodes) do
    for node <- all_nodes, reduce_call?(node), callback_contains?(node, :min) do
      finding(
        :suboptimal,
        "manual min-reduction; review Enum.min/1 only after preserving the initial accumulator, empty-input behavior, and tie selection",
        node
      )
    end
  end

  defp manual_max_reduce(all_nodes) do
    for node <- all_nodes, reduce_call?(node), callback_contains?(node, :max) do
      finding(
        :suboptimal,
        "manual max-reduction; review Enum.max/1 only after preserving the initial accumulator, empty-input behavior, and tie selection",
        node
      )
    end
  end

  defp manual_sum_reduce(all_nodes) do
    for node <- all_nodes, reduce_call?(node), callback_sum?(node) do
      finding(
        :suboptimal,
        "manual sum-reduction; use Enum.sum/1 or Enum.reduce(list, 0, &+/2)",
        node
      )
    end
  end

  defp manual_frequencies(all_nodes) do
    for node <- all_nodes, reduce_call?(node), frequencies_pattern?(node) do
      finding(:suboptimal, "manual frequency counting; use Enum.frequencies/1", node)
    end
  end

  defp reduce_call?(%{type: :call, meta: %{module: Enum, function: :reduce}, source_span: span})
       when not is_nil(span),
       do: true

  defp reduce_call?(_), do: false

  defp callback_contains?(call, target_fn) do
    body = Helpers.callback_body(call)
    significant = Enum.reject(body, &(&1.type in [:var, :literal, :fn, :clause]))

    length(significant) == 1 and
      Enum.any?(significant, &(&1.type == :call and &1.meta[:function] == target_fn))
  end

  defp callback_sum?(call) do
    body = Helpers.callback_body(call)
    significant = Enum.reject(body, &(&1.type in [:var, :literal, :fn, :clause]))

    length(significant) == 1 and
      Enum.any?(significant, &(&1.type == :binary_op and &1.meta[:operator] == :+))
  end

  defp frequencies_pattern?(call) do
    empty_map_acc?(call) and simple_map_update_callback?(call)
  end

  defp empty_map_acc?(%{children: children}) do
    Enum.any?(children, &(&1.type == :map and &1.children == []))
  end

  defp simple_map_update_callback?(call) do
    body = Helpers.callback_body(call)

    top_level_calls =
      Enum.filter(body, fn node ->
        node.type == :call and node.meta[:module] == Map and
          node.meta[:function] in [:update, :update!]
      end)

    top_level_calls != [] and length(body) <= 15
  end
end
