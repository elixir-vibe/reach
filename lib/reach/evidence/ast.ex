defmodule Reach.Evidence.AST do
  @moduledoc "Shared AST helpers for evidence providers."

  def collect(ast, collector) when is_function(collector, 2) do
    ast
    |> reduce([], collector)
    |> Enum.reverse()
  end

  def reduce(ast, initial, reducer) when is_function(reducer, 2) do
    {_ast, acc} = Macro.prewalk(ast, initial, fn node, acc -> {node, reducer.(node, acc)} end)
    acc
  end

  def contains?(ast, predicate) when is_function(predicate, 1) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn node, found? ->
        {node, found? or predicate.(node)}
      end)

    found?
  end

  def count(ast, predicate) when is_function(predicate, 1) do
    {_ast, count} =
      Macro.prewalk(ast, 0, fn node, count ->
        {node, if(predicate.(node), do: count + 1, else: count)}
      end)

    count
  end

  def references?(ast, expected) do
    contains?(ast, &same_ast?(&1, expected))
  end

  def same_ast?(left, right), do: Macro.to_string(left) == Macro.to_string(right)

  def call?(node, {:__local__, function}), do: local_call?(node, function)
  def call?(node, {:erlang, module, function}), do: erlang_call?(node, module, function)
  def call?(node, {module, function}), do: remote_call?(node, module, function)

  def local_call?({function, _meta, args}, function) when is_atom(function) and is_list(args),
    do: true

  def local_call?(_node, _function), do: false

  def remote_call?(
        {{:., _, [{:__aliases__, _, module_parts}, function]}, _, args},
        module,
        function
      )
      when is_list(module_parts) and is_atom(function) and is_atom(module) and is_list(args) do
    safe_module_concat(module_parts) == module
  end

  def remote_call?(_node, _module, _function), do: false

  def erlang_call?({{:., _, [module, function]}, _, args}, module, function)
      when is_atom(module) and is_atom(function) and is_list(args),
      do: true

  def erlang_call?(_node, _module, _function), do: false

  def contains_call?(ast, target), do: contains?(ast, &call?(&1, target))

  def call_descriptor({function, meta, args}) when is_atom(function) and is_list(args) do
    {:ok,
     %{
       module: nil,
       function: function,
       arity: length(args),
       line: meta[:line],
       column: meta[:column]
     }}
  end

  def call_descriptor({{:., meta, [{:__aliases__, _, module_parts}, function]}, _call_meta, args})
      when is_list(module_parts) and is_atom(function) and is_list(args) do
    {:ok,
     %{
       module: safe_module_concat(module_parts),
       function: function,
       arity: length(args),
       line: meta[:line],
       column: meta[:column]
     }}
  end

  def call_descriptor({{:., meta, [module, function]}, _call_meta, args})
      when is_atom(module) and is_atom(function) and is_list(args) do
    {:ok,
     %{
       module: module,
       function: function,
       arity: length(args),
       line: meta[:line],
       column: meta[:column]
     }}
  end

  def call_descriptor(_node), do: :error

  def count_calls(ast, targets) when is_list(targets) do
    count(ast, fn node -> Enum.any?(targets, &call?(node, &1)) end)
  end

  defp safe_module_concat(module_parts) do
    if Enum.all?(module_parts, &is_atom/1) do
      Module.concat(module_parts)
    end
  rescue
    ArgumentError -> nil
  end
end
