defmodule Reach.IR.Helpers do
  @moduledoc "Utility functions for IR node inspection and traversal."

  alias Reach.IR.Node

  def mark_as_definitions(%Node{type: :var, meta: meta} = node) do
    %{node | meta: Map.put(meta, :binding_role, :definition)}
  end

  def mark_as_definitions(%Node{type: :call, meta: %{function: f}} = node)
      when f in [:unquote, :unquote_splicing] do
    node
  end

  def mark_as_definitions(%Node{children: children} = node) do
    %{node | children: Enum.map(children, &mark_as_definitions/1)}
  end

  def mark_as_definitions(other), do: other

  def param_var_name(%Node{type: :var, meta: %{name: name}}), do: name
  def param_var_name(_), do: nil

  def var_used_in_subtree?(%Node{type: :var, meta: %{name: name}}, target), do: name == target

  def var_used_in_subtree?(%Node{children: children}, target) do
    Enum.any?(children, &var_used_in_subtree?(&1, target))
  end

  @doc "Builds a child-node id to direct-parent index."
  @spec direct_parent_index(%{optional(term()) => Node.t()}) :: %{optional(term()) => Node.t()}
  def direct_parent_index(nodes) do
    Enum.reduce(nodes, %{}, fn {_id, node}, parents ->
      Enum.reduce(node.children, parents, &Map.put_new(&2, &1.id, node))
    end)
  end

  @doc "Returns whether a node belongs to a function-clause pattern."
  @spec function_pattern?(Node.t(), map(), map()) :: boolean()
  def function_pattern?(node, function_index, parents) do
    definition_in_subtree?(node) or function_head_pattern?(node, function_index, parents)
  end

  defp definition_in_subtree?(node) do
    node
    |> Reach.IR.all_nodes()
    |> Enum.any?(&(&1.meta[:binding_role] == :definition))
  end

  defp function_head_pattern?(node, function_index, parents) do
    with {_module, _name, arity} <- Map.get(function_index.node_to_function, node.id),
         %Node{type: :clause} = clause <- ancestor_of_type(node, parents, :clause) do
      clause.children
      |> Enum.take(arity)
      |> Enum.any?(&contains_node?(&1, node.id))
    else
      _not_function_head -> false
    end
  end

  defp contains_node?(node, target_id) do
    node
    |> Reach.IR.all_nodes()
    |> Enum.any?(&(&1.id == target_id))
  end

  defp ancestor_of_type(node, parents, type) do
    case Map.get(parents, node.id) do
      %Node{type: ^type} = parent -> parent
      nil -> nil
      parent -> ancestor_of_type(parent, parents, type)
    end
  end

  def location(%Node{} = node) do
    case node.source_span do
      %{file: file, start_line: line} -> "#{file}:#{line}"
      _ -> "unknown"
    end
  end

  def call_name(%Node{} = node) do
    mod = node.meta[:module]
    fun = node.meta[:function]
    if mod, do: "#{inspect(mod)}.#{fun}", else: to_string(fun)
  end

  def func_id_to_string({mod, fun, arity}) when is_atom(mod) and mod != nil do
    "#{inspect(mod)}.#{fun}/#{arity}"
  end

  def func_id_to_string({nil, fun, arity}), do: "#{fun}/#{arity}"
  def func_id_to_string(other), do: inspect(other)

  def module_from_path(path) do
    path
    |> Path.rootname()
    |> Path.split()
    |> Enum.drop_while(&(&1 != "lib" and &1 != "src"))
    |> Enum.drop(1)
    |> Enum.map_join(".", &Macro.camelize/1)
    |> then(fn
      "" -> nil
      name -> Module.concat([name])
    end)
  end

  def clause_labels(func_def) do
    func_def.children
    |> Enum.filter(&(&1.type == :clause))
    |> Enum.map(fn clause ->
      clause.children
      |> Enum.take_while(fn c -> c.type not in [:guard, :block] end)
      |> List.first()
      |> clause_label()
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp clause_label(nil), do: nil
  defp clause_label(%Node{type: :literal, meta: %{value: v}}) when is_binary(v), do: v
  defp clause_label(%Node{type: :literal, meta: %{value: v}}) when is_atom(v), do: inspect(v)

  defp clause_label(%Node{type: :tuple, children: [%Node{type: :literal, meta: %{value: v}} | _]})
       when is_atom(v),
       do: inspect(v)

  defp clause_label(%Node{type: :var, meta: %{name: name}}), do: to_string(name)
  defp clause_label(%Node{type: :match, children: [pattern | _]}), do: clause_label(pattern)
  defp clause_label(_), do: nil
end
