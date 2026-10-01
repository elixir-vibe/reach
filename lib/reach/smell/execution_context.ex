defmodule Reach.Smell.ExecutionContext do
  @moduledoc false

  # Keep lexical definitions and mutually exclusive arms attached to source IR.
  # This is deliberately not a whole-program alias or reachability analysis.
  def annotate(node, contracts \\ %{}) do
    context = %{
      execution: node.id,
      path: %{},
      quoted: false,
      reachable: true,
      module: Map.get(contracts[:owners] || %{}, node.id),
      defined: contracts[:defined] || MapSet.new(),
      no_return: contracts[:no_return] || MapSet.new()
    }

    {node, _bindings} = walk(node, %{}, context)
    node
  end

  # Only source bodies that unconditionally terminate get a no-return contract.
  # Unknown calls, including bang-named helpers, never imply termination.
  def function_contracts(modules) do
    functions = Enum.reduce(modules, %{}, &collect_functions(&1, nil, &2))

    defined =
      MapSet.new(functions, fn {_id, {function, module}} -> function_key(function, module) end)

    context = %{defined: defined, no_return: MapSet.new(), module: nil}

    no_return =
      functions
      |> Enum.filter(fn {_id, {function, module}} ->
        function.children != [] and
          Enum.all?(function.children, &terminal?(&1, %{context | module: module}))
      end)
      |> MapSet.new(fn {_id, {function, module}} -> function_key(function, module) end)

    owners = Map.new(functions, fn {id, {_function, module}} -> {id, module} end)
    %{owners: owners, defined: defined, no_return: no_return}
  end

  def compatible?(left, right) do
    left.meta[:smell_execution] == right.meta[:smell_execution] and
      compatible_paths?(left, right)
  end

  defp compatible_paths?(left, right) do
    Enum.all?(left.meta[:smell_path] || %{}, fn {branch, arm} ->
      case Map.fetch(right.meta[:smell_path] || %{}, branch) do
        {:ok, other_arms} -> not MapSet.disjoint?(arm, other_arms)
        :error -> true
      end
    end)
  end

  defp walk(%{type: :var, meta: %{name: name}} = node, bindings, context) do
    binding =
      if node.meta[:binding_role] == :definition,
        do: node.id,
        else: Map.get(bindings, name, {context.execution, name})

    node = put_context(node, context)
    node = %{node | meta: Map.put(node.meta, :smell_binding, binding)}

    bindings =
      if node.meta[:binding_role] == :definition,
        do: Map.put(bindings, name, binding),
        else: bindings

    {node, bindings}
  end

  defp walk(%{type: :match, children: [pattern, value]} = node, bindings, context) do
    {value, bindings} = walk(value, bindings, context)
    {pattern, bindings} = walk(pattern, bindings, context)
    {%{put_context(node, context) | children: [pattern, value]}, bindings}
  end

  defp walk(%{type: :clause, meta: %{kind: :function_clause}} = node, _bindings, context) do
    context = %{context | execution: node.id, path: %{}, reachable: true}
    {children, bindings} = walk_children(node.children, %{}, context)
    {%{put_context(node, context) | children: children}, bindings}
  end

  defp walk(%{type: :fn} = node, bindings, context) do
    inner = %{context | execution: node.id}

    children =
      Enum.map(node.children, fn child ->
        branch = %{inner | path: Map.put(inner.path, node.id, MapSet.new([child.id]))}
        elem(walk(child, bindings, branch), 0)
      end)

    {%{put_context(node, context) | children: children}, bindings}
  end

  defp walk(
         %{type: :binary_op, meta: %{operator: operator}, children: [left, right]} = node,
         bindings,
         context
       )
       when operator in [:and, :or, :&&, :||] do
    {left, bindings} = walk(left, bindings, context)

    right_context =
      require_truthiness(left, operator in [:and, :&&], normal_continuation(left, context))

    {right, _} = walk(right, bindings, right_context)
    {%{put_context(node, context) | children: [left, right]}, bindings}
  end

  defp walk(%{type: :case, meta: %{desugared_from: :cond}} = node, bindings, context) do
    arms = MapSet.new(node.children, & &1.id)
    condition_context = %{context | path: Map.put(context.path, node.id, arms)}

    {children, _} =
      Enum.map_reduce(node.children, condition_context, fn child, condition_context ->
        [condition, body] = child.children
        {condition, branch_bindings} = walk(condition, bindings, condition_context)
        branch = require_truthiness(condition, true, condition_context)
        branch = %{branch | path: Map.put(branch.path, node.id, MapSet.new([child.id]))}
        {body, _} = walk(body, branch_bindings, branch)
        child = %{put_context(child, branch) | children: [condition, body]}

        next = require_truthiness(condition, false, condition_context)
        remaining = MapSet.delete(Map.fetch!(next.path, node.id), child.id)

        next = %{
          next
          | path: Map.put(next.path, node.id, remaining),
            reachable: next.reachable and MapSet.size(remaining) > 0
        }

        {child, next}
      end)

    {%{put_context(node, context) | children: children}, bindings}
  end

  defp walk(%{type: :case, meta: %{desugared_from: :with}} = node, bindings, context) do
    {children, _} =
      Enum.map_reduce(node.children, bindings, fn
        %{type: :clause, meta: %{kind: :with_clause}, children: [pattern, value]} = child,
        bindings ->
          {value, bindings} = walk(value, bindings, context)
          {pattern, bindings} = walk(define_pattern(pattern), bindings, context)
          {%{put_context(child, context) | children: [pattern, value]}, bindings}

        %{type: :clause, meta: %{kind: :with_clause}} = child, bindings ->
          walk(child, bindings, context)

        child, bindings ->
          branch = %{context | path: Map.put(context.path, node.id, MapSet.new([child.id]))}
          {child, _} = walk(child, bindings, branch)
          {child, bindings}
      end)

    {%{put_context(node, context) | children: children}, bindings}
  end

  defp walk(%{type: type} = node, bindings, context) when type in [:case, :receive] do
    {children, bindings} =
      Enum.map_reduce(node.children, bindings, fn
        %{type: :clause} = child, bindings ->
          branch = %{context | path: Map.put(context.path, node.id, MapSet.new([child.id]))}
          {child, _} = walk(child, bindings, branch)
          {child, bindings}

        child, bindings ->
          walk(child, bindings, context)
      end)

    {%{put_context(node, context) | children: children}, bindings}
  end

  defp walk(%{type: :try, children: [body | _]} = node, bindings, context) do
    children =
      Enum.map(node.children, fn child ->
        branch =
          case child.type do
            :after ->
              context

            :clause ->
              path =
                context.path
                |> Map.put(node.id, MapSet.new([body.id]))
                |> Map.put({node.id, :else}, MapSet.new([child.id]))

              %{context | path: path}

            _ ->
              %{context | path: Map.put(context.path, node.id, MapSet.new([child.id]))}
          end

        elem(walk(child, bindings, branch), 0)
      end)

    {%{put_context(node, context) | children: children}, bindings}
  end

  defp walk(%{type: :comprehension} = node, bindings, context) do
    inner = %{context | execution: node.id}
    {children, _} = walk_children(node.children, bindings, inner)
    {%{put_context(node, context) | children: children}, bindings}
  end

  # Ash's expression filter argument is syntax, not a runtime call tree. The
  # keyword/do forms are runtime expressions; pins inside the DSL are runtime too.
  defp walk(
         %{
           type: :call,
           meta: %{module: Ash.Query, function: :filter, arity: 2},
           children: [query, expression]
         } = node,
         bindings,
         context
       )
       when expression.type not in [:list, :map, :struct, :literal] do
    {query, bindings} = walk(query, bindings, context)
    {expression, _} = walk(expression, bindings, %{context | quoted: true})
    {%{put_context(node, context) | children: [query, expression]}, bindings}
  end

  defp walk(%{type: :pin} = node, bindings, %{quoted: true} = context) do
    {children, bindings} = walk_children(node.children, bindings, %{context | quoted: false})
    {%{put_context(node, context) | children: children}, bindings}
  end

  defp walk(%{type: :pin} = node, bindings, context) do
    children = Enum.map(node.children, &clear_definitions/1)
    {children, bindings} = walk_children(children, bindings, context)
    {%{put_context(node, context) | children: children}, bindings}
  end

  defp walk(node, bindings, context) do
    {children, bindings} = walk_children(node.children || [], bindings, context)
    {%{put_context(node, context) | children: children}, bindings}
  end

  defp walk_children(children, bindings, context) do
    {children, {bindings, _context}} =
      Enum.map_reduce(children, {bindings, context}, fn child, {bindings, context} ->
        {child, bindings} = walk(child, bindings, context)
        {child, {bindings, normal_continuation(child, context)}}
      end)

    {children, bindings}
  end

  defp require_truthiness(%{type: :var, meta: %{smell_binding: binding}}, truthy, context) do
    key = {:truthiness, binding}
    required = MapSet.new([truthy])
    allowed = MapSet.intersection(Map.get(context.path, key, required), required)

    %{
      context
      | path: Map.put(context.path, key, allowed),
        reachable: context.reachable and MapSet.size(allowed) > 0
    }
  end

  defp require_truthiness(
         %{type: :unary_op, meta: %{operator: operator}, children: [value]},
         truthy,
         context
       )
       when operator in [:not, :!] do
    require_truthiness(value, not truthy, context)
  end

  defp require_truthiness(%{type: :literal, meta: %{value: value}}, truthy, context) do
    %{context | reachable: context.reachable and value not in [nil, false] == truthy}
  end

  defp require_truthiness(_node, _truthy, context), do: context

  defp define_pattern(%{type: :pin} = node), do: node

  defp define_pattern(%{type: :var} = node),
    do: %{node | meta: Map.put(node.meta, :binding_role, :definition)}

  defp define_pattern(
         %{type: :call, meta: %{function: :when}, children: [pattern | guards]} = node
       ),
       do: %{node | children: [define_pattern(pattern) | guards]}

  defp define_pattern(node),
    do: %{node | children: Enum.map(node.children, &define_pattern/1)}

  defp clear_definitions(node) do
    %{
      node
      | meta: Map.delete(node.meta, :binding_role),
        children: Enum.map(node.children, &clear_definitions/1)
    }
  end

  defp collect_functions(%{type: :module_def} = node, _module, functions) do
    Enum.reduce(node.children, functions, &collect_functions(&1, node.meta[:name], &2))
  end

  defp collect_functions(%{type: :function_def} = node, module, functions),
    do: Map.put(functions, node.id, {node, module})

  defp collect_functions(node, module, functions),
    do: Enum.reduce(node.children, functions, &collect_functions(&1, module, &2))

  defp function_key(node, module), do: {module, node.meta[:name], node.meta[:arity]}

  defp normal_continuation(%{type: :match, children: [_, value]}, context),
    do: normal_continuation(value, context)

  defp normal_continuation(%{type: :block, children: children}, context),
    do: Enum.reduce(children, context, &normal_continuation/2)

  defp normal_continuation(%{type: :case, meta: %{desugared_from: :with}}, context),
    do: context

  defp normal_continuation(%{type: :case} = node, context) do
    clauses = Enum.filter(node.children, &(&1.type == :clause))
    returning = Enum.reject(clauses, &terminal?(&1, context))

    if length(returning) != length(clauses) do
      arms = MapSet.new(returning, & &1.id)

      %{
        context
        | path: Map.put(context.path, node.id, arms),
          reachable: context.reachable and returning != []
      }
    else
      context
    end
  end

  defp normal_continuation(node, context) do
    if terminal?(node, context), do: %{context | reachable: false}, else: context
  end

  defp terminal?(%{meta: %{smell_quoted: true}}, _context), do: false

  defp terminal?(%{type: :clause, children: children}, context),
    do: children != [] and terminal?(List.last(children), context)

  defp terminal?(%{type: :block, children: children}, context),
    do: Enum.any?(children, &terminal?(&1, context))

  defp terminal?(%{type: :match, children: [_, value]}, context),
    do: terminal?(value, context)

  defp terminal?(%{type: :case, meta: %{desugared_from: :with}}, _context), do: false

  defp terminal?(%{type: :case} = node, context) do
    clauses = Enum.filter(node.children, &(&1.type == :clause))
    clauses != [] and Enum.all?(clauses, &terminal?(&1, context))
  end

  defp terminal?(%{type: :call, meta: meta}, context) do
    module = meta[:module] || context.module
    key = {module, meta[:function], meta[:arity]}

    builtin =
      (meta[:module] == Kernel or
         (meta[:module] == nil and not MapSet.member?(context.defined, key))) and
        {meta[:function], meta[:arity]} in [
          {:raise, 1},
          {:raise, 2},
          {:reraise, 2},
          {:reraise, 3},
          {:throw, 1},
          {:exit, 1}
        ]

    erlang =
      meta[:module] == :erlang and
        {meta[:function], meta[:arity]} in [
          {:error, 1},
          {:error, 2},
          {:error, 3},
          {:raise, 3},
          {:throw, 1},
          {:exit, 1}
        ]

    builtin or erlang or MapSet.member?(context.no_return, key)
  end

  defp terminal?(_node, _context), do: false

  defp put_context(node, context) do
    meta =
      node.meta
      |> Map.put(:smell_execution, context.execution)
      |> Map.put(:smell_path, context.path)
      |> Map.put(:smell_quoted, context.quoted)
      |> Map.put(:smell_reachable, context.reachable)

    %{node | meta: meta}
  end
end
