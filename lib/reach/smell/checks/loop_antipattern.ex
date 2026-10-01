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
        quadratic_concat?(node, function) do
      finding(
        :suboptimal,
        "++ inside reduce is O(n²); prepend with [item | acc] and Enum.reverse/1 after",
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
    Helpers.growing_accumulator_concat?(node, function) or
      recursive_operand?(node, function)
  end

  defp recursive_operand?(%{children: [left, right]} = node, function) do
    self_call?(left, function) or
      (node.meta[:operator] == :<> and self_call?(right, function))
  end

  defp recursive_operand?(_, _), do: false

  # ++ copies only its left operand. A recursive result on the right is
  # an ordinary list tail, not the quadratic prefix described by this check.
  defp self_call?(%{type: :call} = node, function) do
    node.meta[:function] == function.meta[:name] and
      node.meta[:arity] == function.meta[:arity] and node.meta[:module] == nil
  end

  defp self_call?(_, _), do: false

  defp manual_min_reduce(all_nodes) do
    for node <- all_nodes, reduce_call?(node), callback_contains?(node, :min) do
      finding(:suboptimal, "manual min-reduction; use Enum.min/1 or Enum.min_by/2", node)
    end
  end

  defp manual_max_reduce(all_nodes) do
    for node <- all_nodes, reduce_call?(node), callback_contains?(node, :max) do
      finding(:suboptimal, "manual max-reduction; use Enum.max/1 or Enum.max_by/2", node)
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
    case call.children do
      [
        _source,
        %{type: :map, children: []},
        %{type: :fn, meta: %{kind: :capture}, children: [update]}
      ] ->
        counting_update?(update, {:capture, 1}, {:capture, 2})

      [_source, %{type: :map, children: []}, %{type: :fn, children: [clause]}] ->
        case clause.children do
          [%{type: :var} = item, %{type: :var} = accumulator, update] ->
            counting_update?(update, item, accumulator)

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp counting_update?(
         %{
           type: :call,
           meta: %{module: Map, function: :update},
           children: [map, key, %{type: :literal, meta: %{value: 1}}, increment]
         },
         item,
         accumulator
       ) do
    same_variable?(map, accumulator) and same_variable?(key, item) and
      increment_by_one?(increment)
  end

  defp counting_update?(_, _, _), do: false

  defp increment_by_one?(%{type: :fn, meta: %{kind: :capture}, children: [addition]}),
    do: addition_by_one?(addition, {:capture, 1})

  defp increment_by_one?(%{
         type: :fn,
         children: [%{type: :clause, children: [parameter, addition]}]
       }),
       do: addition_by_one?(addition, parameter)

  defp increment_by_one?(_), do: false

  defp addition_by_one?(
         %{
           type: :binary_op,
           meta: %{operator: :+},
           children: [value, %{type: :literal, meta: %{value: 1}}]
         },
         parameter
       ),
       do: same_variable?(value, parameter)

  defp addition_by_one?(
         %{
           type: :binary_op,
           meta: %{operator: :+},
           children: [%{type: :literal, meta: %{value: 1}}, value]
         },
         parameter
       ),
       do: same_variable?(value, parameter)

  defp addition_by_one?(_, _), do: false

  defp same_variable?(
         %{
           type: :fn,
           meta: %{kind: :capture},
           children: [%{type: :literal, meta: %{value: index}}]
         },
         {:capture, index}
       ),
       do: true

  defp same_variable?(
         %{type: :var, meta: %{name: name}},
         %{type: :var, meta: %{name: name}}
       ),
       do: true

  defp same_variable?(_, _), do: false
end
