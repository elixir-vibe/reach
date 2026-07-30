defmodule Reach.DataDependence do
  @moduledoc "Computes data dependence (def-use chains) from IR."

  alias Reach.IR
  alias Reach.IR.Node

  @doc """
  Builds a data dependence graph from IR nodes.

  Returns a `Graph.t()` where edges represent data flow from definitions to uses.
  """
  @spec build([Node.t()] | Node.t()) :: Graph.t()
  def build(nodes) do
    nodes = List.wrap(nodes)
    all = IR.all_nodes(nodes)

    bindings = Map.new(all, fn node -> {node.id, analyze_bindings(node)} end)
    scope_map = build_scope_map(nodes)
    scoped_defs = build_scoped_def_map(all, bindings, scope_map)

    graph = build_def_use_edges(all, bindings, scoped_defs, scope_map)
    graph |> add_containment_edges(all) |> add_match_binding_edges(all)
  end

  @doc """
  Analyzes which variables a node defines and uses.
  """
  @spec analyze_bindings(Node.t()) :: {[atom()], [atom()]}
  def analyze_bindings(%Node{type: :var, meta: %{binding_role: :definition, name: name}}) do
    {[name], []}
  end

  def analyze_bindings(%Node{type: :var, meta: %{name: name}}), do: {[], [name]}

  def analyze_bindings(%Node{type: :pin, children: [%Node{type: :var, meta: %{name: name}}]}) do
    {[], [name]}
  end

  def analyze_bindings(_), do: {[], []}

  @doc """
  Collects variable names defined by a pattern.
  """
  @spec collect_definitions(Node.t()) :: [atom()]
  def collect_definitions(%Node{type: :var, meta: %{name: name}}), do: [name]
  def collect_definitions(%Node{type: :pin}), do: []

  def collect_definitions(%Node{type: type, children: children})
      when type in [:tuple, :list, :cons, :map, :map_field, :struct, :match, :binary_op] do
    Enum.flat_map(children, &collect_definitions/1)
  end

  def collect_definitions(_), do: []

  # --- Scope tracking ---

  # Scope-introducing nodes: clause, fn, comprehension create new scopes
  # where variables defined inside don't leak out.
  @scope_types [:clause, :fn, :comprehension]

  defp build_scope_map(nodes) do
    {map, _} = walk_scopes(nodes, nil, %{})
    map
  end

  defp walk_scopes(nodes, parent_scope, acc) when is_list(nodes) do
    Enum.reduce(nodes, {acc, parent_scope}, fn node, {a, ps} ->
      walk_scopes(node, ps, a)
    end)
  end

  defp walk_scopes(%Node{type: type, id: id, children: children}, parent_scope, acc)
       when type in @scope_types do
    acc = Map.put(acc, id, parent_scope)
    {acc, _} = walk_scopes(children, id, acc)
    {acc, parent_scope}
  end

  defp walk_scopes(%Node{id: id, children: children}, parent_scope, acc) do
    acc = Map.put(acc, id, parent_scope)
    {acc, _} = walk_scopes(children, parent_scope, acc)
    {acc, parent_scope}
  end

  # --- Scoped def-use resolution ---

  defp build_scoped_def_map(all_nodes, bindings, scope_map) do
    Enum.reduce(all_nodes, %{}, fn node, acc ->
      {defs, _} = Map.get(bindings, node.id, {[], []})
      scope = Map.get(scope_map, node.id)

      Enum.reduce(defs, acc, fn var_name, inner ->
        Map.update(inner, {scope, var_name}, [node.id], &[node.id | &1])
      end)
    end)
  end

  defp resolve_def(scoped_defs, _scope_map, nil, var_name) do
    Map.get(scoped_defs, {nil, var_name}, [])
  end

  defp resolve_def(scoped_defs, scope_map, scope, var_name) do
    case Map.get(scoped_defs, {scope, var_name}) do
      nil -> resolve_def(scoped_defs, scope_map, Map.get(scope_map, scope), var_name)
      def_ids -> def_ids
    end
  end

  defp build_def_use_edges(all_nodes, bindings, scoped_defs, scope_map) do
    Enum.reduce(all_nodes, Graph.new(), fn node, graph ->
      {_, uses} = Map.get(bindings, node.id, {[], []})
      scope = Map.get(scope_map, node.id)
      add_use_edges(graph, node, uses, scope, scoped_defs, scope_map)
    end)
  end

  defp add_use_edges(graph, node, uses, scope, scoped_defs, scope_map) do
    Enum.reduce(uses, graph, fn var_name, g ->
      scoped_defs
      |> resolve_def(scope_map, scope, var_name)
      |> Enum.reject(&(&1 == node.id))
      |> Enum.reduce(g, fn def_id, g2 ->
        g2
        |> Graph.add_vertex(def_id)
        |> Graph.add_vertex(node.id)
        |> Graph.add_edge(def_id, node.id, label: {:data, var_name})
      end)
    end)
  end

  # --- Containment edges ---

  defp add_containment_edges(graph, all_nodes) do
    all_nodes
    |> Enum.filter(&value_depends_on_children?/1)
    |> Enum.reduce(graph, &add_child_edges/2)
  end

  defp add_child_edges(node, graph) do
    Enum.reduce(node.children, graph, fn child, g ->
      g
      |> Graph.add_vertex(child.id)
      |> Graph.add_vertex(node.id)
      |> Graph.add_edge(child.id, node.id, label: :containment)
    end)
  end

  @value_types [
    :binary_op,
    :unary_op,
    :call,
    :tuple,
    :list,
    :cons,
    :map,
    :map_field,
    :struct,
    :match,
    :comprehension,
    :case,
    :fn,
    :receive,
    :try,
    :guard,
    :quote
  ]

  defp add_match_binding_edges(graph, all_nodes) do
    all_nodes
    |> Enum.filter(&(&1.type == :match and length(&1.children) == 2))
    |> Enum.reduce(graph, fn match_node, g ->
      [lhs, rhs] = match_node.children
      connect_rhs_to_defs(g, rhs, lhs)
    end)
  end

  defp connect_rhs_to_defs(graph, rhs, lhs) do
    lhs
    |> Reach.IR.all_nodes()
    |> Enum.filter(&(&1.type == :var and &1.meta[:binding_role] == :definition))
    |> Enum.reduce(graph, fn def_var, g ->
      g
      |> Graph.add_vertex(rhs.id)
      |> Graph.add_vertex(def_var.id)
      |> Graph.add_edge(rhs.id, def_var.id, label: :match_binding)
    end)
  end

  defp value_depends_on_children?(%Node{type: type}) when type in @value_types, do: true
  defp value_depends_on_children?(_), do: false
end
