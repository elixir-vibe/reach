defmodule Reach.Smell.Helpers do
  @moduledoc "Shared helpers for smell checks including loop detection, statement pairs, and callbacks."

  alias Reach.IR
  alias Reach.IR.Helpers, as: IRHelpers

  @loop_fns ~w(
    each map flat_map filter reject reduce reduce_while map_reduce flat_map_reduce
    find find_value find_index all? any? count sum_by product_by
    min_by max_by min_max_by frequencies_by group_by
    sort sort_by chunk_by chunk_while dedup_by uniq_by
    split_while split_with take_while drop_while partition
    scan map_every map_join map_intersperse into zip_with zip_reduce
  )a

  @accumulator_fns ~w(reduce reduce_while scan flat_map_reduce map_reduce zip_reduce)a

  def function_defs(project) do
    for {_id, node} <- project.nodes, node.type == :function_def, do: node
  end

  def location(node) do
    case node.source_span do
      %{file: file, start_line: line} -> "#{file}:#{line}"
      _ -> "unknown"
    end
  end

  def call_name(node), do: IRHelpers.call_name(node)

  @doc "Returns true if `node` is inside a loop body (reduce/map/for/recursion)."
  def inside_loop?(node, function) do
    ancestors = ancestors_of(node.id, function)

    Enum.any?(ancestors, fn ancestor ->
      fn_inside_loop_call?(ancestor, function) or
        ancestor.type == :comprehension
    end) or inside_recursive_clause?(node, function)
  end

  @doc "Returns true if `node` is inside an accumulator-carrying loop (reduce/scan)."
  def inside_accumulator?(node, function) do
    ancestors = ancestors_of(node.id, function)

    Enum.any?(ancestors, fn ancestor ->
      fn_inside_accumulator_call?(ancestor, function)
    end)
  end

  @doc "Extracts the callback fn body nodes from an Enum call."
  def callback_body(%{type: :call, children: children}) do
    children
    |> Enum.find(&(&1.type == :fn))
    |> case do
      nil -> []
      fn_node -> IR.all_nodes(fn_node)
    end
  end

  def callback_body(_), do: []

  @doc "Returns adjacent top-level statement pairs from a function body."
  def statement_pairs(function) do
    function
    |> body_statements()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> {a, b} end)
  end

  @doc "Returns true if the function contains a self-recursive call."
  def recursive?(function) do
    name = function.meta[:name]
    arity = function.meta[:arity]

    function
    |> IR.all_nodes()
    |> Enum.any?(fn node ->
      node.type == :call and node.meta[:function] == name and
        node.meta[:arity] == arity and node.meta[:module] == nil
    end)
  end

  defp fn_inside_loop_call?(node, function),
    do: fn_inside_call?(node, function, @loop_fns)

  defp fn_inside_accumulator_call?(node, function),
    do: fn_inside_call?(node, function, @accumulator_fns)

  defp fn_inside_call?(node, function, target_fns) do
    node.type == :fn and
      Enum.any?(ancestors_of(node.id, function), fn ancestor ->
        ancestor.type == :call and ancestor.meta[:module] in [Enum, Stream] and
          ancestor.meta[:function] in target_fns and
          List.last(ancestor.children).id == node.id
      end)
  end

  defp inside_recursive_clause?(node, function) do
    ancestors_of(node.id, function)
    |> Enum.find(&(&1.type == :clause and &1.meta[:kind] == :function_clause))
    |> case do
      nil -> false
      clause -> clause_cycle?(clause, clause.id, function, MapSet.new([clause.id]))
    end
  end

  # Calling a different literal-dispatched clause once is not iteration.
  # Follow possible clause transitions and require a cycle back to this body.
  defp clause_cycle?(clause, target_id, function, visited) do
    clause
    |> IR.all_nodes()
    |> Enum.filter(fn node ->
      node.type == :call and node.meta[:function] == function.meta[:name] and
        node.meta[:arity] == function.meta[:arity] and node.meta[:module] == nil
    end)
    |> Enum.any?(fn call ->
      Enum.any?(
        function.children,
        &cycle_candidate?(&1, call, target_id, function, visited)
      )
    end)
  end

  defp cycle_candidate?(candidate, call, target_id, function, visited) do
    candidate.type == :clause and possible_clause?(candidate, call) and
      (candidate.id == target_id or
         (not MapSet.member?(visited, candidate.id) and
            clause_cycle?(candidate, target_id, function, MapSet.put(visited, candidate.id))))
  end

  defp possible_clause?(clause, call) do
    clause.children
    |> Enum.take(call.meta[:arity])
    |> Enum.zip(call.children)
    |> Enum.all?(fn
      {%{type: :literal, meta: %{value: pattern}}, %{type: :literal, meta: %{value: argument}}} ->
        pattern === argument

      _ ->
        true
    end)
  end

  @doc "Proves concatenation copies an accumulator that is returned to the next iteration."
  def growing_accumulator_concat?(%{type: :binary_op, children: [left, right]} = node, function) do
    operands = if node.meta[:operator] == :<>, do: [left, right], else: [left]
    growing_feedback?(node, operands, function)
  end

  def growing_accumulator_concat?(%{type: :call, meta: %{function: :<<>>}} = node, function) do
    operands =
      Enum.flat_map(node.children, fn
        %{
          type: :call,
          meta: %{function: :"::"},
          children: [
            %{type: :call, meta: %{module: Kernel, function: :to_string}, children: [value]},
            _
          ]
        } ->
          [value]

        _ ->
          []
      end)

    growing_feedback?(node, operands, function)
  end

  def growing_accumulator_concat?(_, _), do: false

  defp growing_feedback?(node, operands, function) do
    node.id
    |> ancestors_of(function)
    |> Enum.filter(&(&1.type == :fn))
    |> Enum.any?(fn callback ->
      call =
        callback.id
        |> ancestors_of(function)
        |> Enum.find(fn ancestor ->
          ancestor.type == :call and List.last(ancestor.children).id == callback.id
        end)

      cond do
        call && accumulator_call?(call) &&
            not fixed_enumeration?(List.first(call.children)) ->
          callback_feedback?(node, operands, callback, call, 2)

        map_update_call?(call) ->
          callback_feedback?(node, operands, callback, call, 1) and
            growing_feedback?(call, [List.first(call.children)], function)

        true ->
          false
      end
    end)
  end

  defp callback_feedback?(node, operands, callback, call, capture_index) do
    case accumulator_callback(callback, node.id, capture_index) do
      {accumulator, body} ->
        Enum.any?(operands, &operand_feedback?(&1, accumulator, body, node.id, call))

      _ ->
        false
    end
  end

  defp operand_feedback?(operand, accumulator, body, node_id, call) do
    case accumulator_operand_path(operand, accumulator) do
      {:ok, path} -> returned_node?(body, node_id, feedback_path(call, path))
      _ -> false
    end
  end

  defp map_update_call?(%{type: :call, meta: %{module: Map, function: function}}),
    do: function in [:update, :update!]

  defp map_update_call?(_), do: false

  defp accumulator_call?(node) do
    node.type == :call and node.meta[:module] in [Enum, Stream] and
      node.meta[:function] in @accumulator_fns
  end

  defp accumulator_callback(%{meta: %{kind: :capture}, children: [body]}, _, index),
    do: {{:capture, index}, body}

  defp accumulator_callback(callback, node_id, minimum_arity) do
    with %{type: :clause} = clause <-
           Enum.find(callback.children, fn child ->
             child.type == :clause and
               Enum.any?(IR.all_nodes(child), &(&1.id == node_id))
           end),
         parameters <- clause.children |> Enum.reject(&(&1.type == :guard)) |> Enum.drop(-1),
         true <- length(parameters) >= minimum_arity do
      {List.last(parameters), List.last(clause.children)}
    else
      _ -> nil
    end
  end

  defp accumulator_operand_path(
         %{
           type: :fn,
           meta: %{kind: :capture},
           children: [%{type: :literal, meta: %{value: index}}]
         },
         {:capture, index}
       ),
       do: {:ok, []}

  defp accumulator_operand_path(%{type: :var, meta: %{name: name}}, accumulator)
       when is_map(accumulator),
       do: parameter_path(accumulator, name, [])

  defp accumulator_operand_path(
         %{type: :call, meta: %{kind: :field_access, function: field}, children: [receiver]},
         accumulator
       ),
       do: projected_path(receiver, {:literal, field}, accumulator)

  defp accumulator_operand_path(
         %{
           type: :call,
           meta: %{module: module, function: function},
           children: [receiver, key | _]
         },
         accumulator
       )
       when (module == Map and function in [:get, :fetch!]) or
              (module == Access and function == :get),
       do: projected_path(receiver, key_shape(key), accumulator)

  defp accumulator_operand_path(_, _), do: nil

  defp projected_path(receiver, key, accumulator) do
    case accumulator_operand_path(receiver, accumulator) do
      {:ok, path} -> {:ok, path ++ [{:key, key}]}
      _ -> nil
    end
  end

  defp key_shape(%{type: :literal, meta: %{value: value}}), do: {:literal, value}
  defp key_shape(%{type: :var, meta: %{name: name}}), do: {:var, name}

  defp key_shape(node),
    do:
      {node.type, Map.take(node.meta, [:module, :function, :operator]),
       Enum.map(node.children, &key_shape/1)}

  defp parameter_path(%{type: :var, meta: %{name: name}}, name, path), do: {:ok, path}

  defp parameter_path(%{type: :tuple, children: children}, name, path) do
    children
    |> Enum.with_index()
    |> Enum.find_value(fn {child, index} -> parameter_path(child, name, path ++ [index]) end)
  end

  defp parameter_path(%{type: type, children: children}, name, path)
       when type in [:map, :struct] do
    Enum.find_value(children, fn
      %{type: :map_field, children: [key, value]} ->
        parameter_path(value, name, path ++ [{:key, key_shape(key)}])

      _ ->
        nil
    end)
  end

  defp parameter_path(_, _, _), do: nil

  defp feedback_path(%{meta: %{function: :reduce_while}}, path), do: [:cont | path]

  defp feedback_path(%{meta: %{function: function}}, path)
       when function in [:map_reduce, :flat_map_reduce], do: [1 | path]

  defp feedback_path(_, path), do: path

  # A literal proper list has a constant number of iterations, regardless of
  # the sizes of the values it contains. No arbitrary "small loop" threshold.
  defp fixed_enumeration?(%{type: :list, children: children}),
    do: Enum.all?(children, &(&1.type != :cons and &1.meta[:function] != :|))

  defp fixed_enumeration?(%{type: :literal, meta: %{value: value}}), do: is_list(value)
  defp fixed_enumeration?(_), do: false

  # Calls consume their arguments; an argument is not itself the returned
  # accumulator (e.g. a binary chunk passed into a parser).
  defp returned_node?(%{id: id}, target, []) when id == target, do: true

  defp returned_node?(%{type: :block, children: children}, target, path) do
    case List.last(children) do
      %{type: :var, meta: %{name: name}} ->
        children
        |> Enum.drop(-1)
        |> Enum.reverse()
        |> Enum.find_value(fn
          %{type: :match, children: [%{type: :var, meta: %{name: ^name}}, value]} ->
            {:value, value}

          _ ->
            nil
        end)
        |> case do
          {:value, value} -> returned_node?(value, target, path)
          _ -> false
        end

      value ->
        returned_node?(value, target, path)
    end
  end

  defp returned_node?(
         %{
           type: :tuple,
           children: [
             %{type: :literal, meta: %{value: :cont}},
             value
           ]
         },
         target,
         [:cont | path]
       ),
       do: returned_node?(value, target, path)

  defp returned_node?(%{type: :tuple, children: children}, target, [index | path])
       when is_integer(index),
       do: returned_node?(Enum.at(children, index), target, path)

  defp returned_node?(%{type: type, children: children}, target, [{:key, key} | path])
       when type in [:map, :struct] do
    Enum.any?(children, fn
      %{type: :map_field, children: [field, value]} ->
        key_shape(field) == key and returned_node?(value, target, path)

      %{type: :map} = update ->
        returned_node?(update, target, [{:key, key} | path])

      _ ->
        false
    end)
  end

  defp returned_node?(
         %{type: :call, meta: %{module: Map, function: :put}, children: [_map, field, value]},
         target,
         [{:key, key} | path]
       ),
       do: key_shape(field) == key and returned_node?(value, target, path)

  defp returned_node?(
         %{type: :call, meta: %{module: Map, function: function}, children: children},
         target,
         [{:key, key} | path]
       )
       when function in [:update, :update!] do
    [_map, field | _] = children
    callback = List.last(children)

    key_shape(field) == key and
      Enum.any?(callback.children, &returned_node?(&1, target, path))
  end

  defp returned_node?(%{type: :case, children: children}, target, path),
    do:
      children
      |> Enum.filter(&(&1.type == :clause))
      |> Enum.any?(&returned_node?(&1, target, path))

  defp returned_node?(%{type: :clause, children: children}, target, path),
    do: returned_node?(List.last(children), target, path)

  defp returned_node?(%{type: :match, children: [_, value]}, target, path),
    do: returned_node?(value, target, path)

  defp returned_node?(_, _, _), do: false

  defp ancestors_of(target_id, root) do
    case find_path(root, target_id, []) do
      nil -> []
      path -> path
    end
  end

  defp find_path(%{id: id} = node, target_id, path) do
    if id == target_id do
      path
    else
      Enum.find_value(node.children, fn child ->
        find_path(child, target_id, [node | path])
      end)
    end
  end

  defp body_statements(function) do
    case function.children do
      [%{type: :clause, children: children} | _] ->
        children
        |> Enum.reject(&(&1.type in [:guard]))
        |> Enum.drop(function.meta[:arity] || 0)
        |> Enum.flat_map(&unwrap_block/1)

      children ->
        children
    end
  end

  defp unwrap_block(%{type: :block, children: children}), do: children
  defp unwrap_block(node), do: [node]
end
