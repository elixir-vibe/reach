defmodule Reach.CallGraph do
  @moduledoc "Builds call graph edges between function definitions."

  alias Reach.IR
  alias Reach.IR.Node

  @type function_id :: {module(), atom(), non_neg_integer()}

  @doc """
  Builds a call graph from a list of IR nodes (typically a whole module).

  Returns a `Graph.t()` where vertices are `{module, function, arity}` tuples
  and edges are labeled with the call site node ID.
  """
  @spec build([Node.t()], keyword()) :: Graph.t()
  def build(ir_nodes, opts \\ []) do
    module_name = Keyword.get(opts, :module)
    all_nodes = Keyword.get_lazy(opts, :all_nodes, fn -> IR.all_nodes(ir_nodes) end)

    func_defs = collect_function_defs(all_nodes, module_name)
    call_sites = collect_call_sites(all_nodes, module_name)

    graph =
      Enum.reduce(func_defs, Graph.new(), fn {_fun_id, node}, g ->
        Graph.add_vertex(g, function_id(node, module_name))
      end)

    Enum.reduce(call_sites, graph, fn {caller_id, callee_id, call_node_id}, g ->
      g
      |> Graph.add_vertex(caller_id)
      |> Graph.add_vertex(callee_id)
      |> Graph.add_edge(caller_id, callee_id, label: {:call, call_node_id})
    end)
  end

  @doc """
  Collects all function definitions as `{function_id, ir_node}` pairs.
  """
  @spec collect_function_defs([Node.t()], module() | nil) :: [{function_id(), Node.t()}]
  def collect_function_defs(all_nodes, module_name) do
    for node <- all_nodes,
        node.type == :function_def,
        name = node.meta[:name],
        arity = node.meta[:arity],
        name != nil do
      {{module_name, name, arity}, node}
    end
  end

  @doc """
  Finds which function definition contains a given node, based on the IR tree.
  """
  @spec find_enclosing_function([Node.t()], Node.id()) :: function_id() | nil
  def find_enclosing_function(ir_nodes, target_id) do
    find_enclosing(ir_nodes, target_id, nil)
  end

  defp find_enclosing(nodes, target_id, current_func) when is_list(nodes) do
    Enum.find_value(nodes, fn node -> find_enclosing(node, target_id, current_func) end)
  end

  defp find_enclosing(%Node{id: id, type: :function_def} = node, target_id, _current_func) do
    func_id = {nil, node.meta[:name], node.meta[:arity]}

    if id == target_id do
      func_id
    else
      find_enclosing(node.children, target_id, func_id)
    end
  end

  defp find_enclosing(%Node{id: id} = node, target_id, current_func) do
    if id == target_id do
      current_func
    else
      find_enclosing(node.children, target_id, current_func)
    end
  end

  defp collect_call_sites(all_nodes, module_name) do
    parent_map = build_parent_map(all_nodes)

    # Only definitions that carry their own module metadata can anchor a local call.
    defined =
      for node <- all_nodes,
          node.type == :function_def and node.meta[:module] != nil,
          into: MapSet.new(),
          do: function_id(node, module_name)

    for call_node <- all_nodes,
        call_node.type == :call,
        caller_def = Map.get(parent_map, call_node.id),
        caller_def != nil do
      {caller_module, _name, _arity} = caller_id = function_id(caller_def, module_name)
      callee_id = call_node |> call_target() |> resolve_local(caller_module, defined)
      {caller_id, callee_id, call_node.id}
    end
  end

  # The defmodule a definition was parsed in wins over the path-derived module name.
  defp function_id(node, module_name),
    do: {node.meta[:module] || module_name, node.meta[:name], node.meta[:arity]}

  # Local calls carry no module; bind them to the caller's module when it defines them.
  defp resolve_local({nil, fun, arity} = callee, caller_module, defined) do
    if MapSet.member?(defined, {caller_module, fun, arity}),
      do: {caller_module, fun, arity},
      else: callee
  end

  defp resolve_local(callee, _caller_module, _defined), do: callee

  defp build_parent_map(all_nodes) do
    func_defs = Enum.filter(all_nodes, &(&1.type == :function_def))

    Enum.reduce(func_defs, %{}, fn func_def, acc ->
      func_def
      |> Reach.IR.all_nodes()
      |> Enum.reduce(acc, &Map.put_new(&2, &1.id, func_def))
    end)
  end

  defp call_target(%Node{type: :call, meta: meta}) do
    {meta[:module], meta[:function], meta[:arity] || 0}
  end
end
