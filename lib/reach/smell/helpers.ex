defmodule Reach.Smell.Helpers do
  @moduledoc "Shared helpers for smell checks including loop detection, statement pairs, and callbacks."

  alias Reach.IR

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

  def source_location(%{file: file, line: line}), do: "#{file}:#{line}"
  def source_location(%{line: line}), do: "line #{line}"
  def source_location(_source), do: "unknown"

  @doc "Returns a deterministic source-order key for an IR node."
  def source_sort_key(node) do
    case node.source_span do
      %{file: file, start_line: line} = span ->
        {file, line, Map.get(span, :start_col) || 0, node.id}

      _span ->
        {"", 0, 0, node.id}
    end
  end

  def ast_modules_in_file(ast), do: Reach.AST.modules_in_file(ast)

  @doc "Returns true if `node` is inside a loop body (reduce/map/for/recursion)."
  def inside_loop?(node, function) do
    ancestors = ancestors_of(node.id, function)

    Enum.any?(ancestors, fn ancestor ->
      fn_inside_loop_call?(ancestor, function) or
        ancestor.type == :comprehension
    end) or recursive?(function)
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

  @doc "Returns true when an AST node is an identity anonymous function."
  def identity_fn?({:fn, _, [{:->, _, [[{var, _, ctx}], {var, _, ctx}]}]})
      when is_atom(var) and is_atom(ctx),
      do: true

  def identity_fn?({:&, _, [{:&, _, [1]}]}), do: true
  def identity_fn?({:&, _, [{:&, _, [{:__block__, _, [1]}]}]}), do: true
  def identity_fn?(_callback), do: false

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
          ancestor.meta[:function] in target_fns
      end)
  end

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

  @doc "Returns top-level statements from a function body."
  def body_statements(function) do
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
