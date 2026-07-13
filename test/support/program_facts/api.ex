defmodule Reach.Test.ProgramFacts.API do
  @moduledoc false

  alias Reach.Test.ProgramFacts.{Normalize, Project}

  def analyze(program) do
    Project.with_project(program, fn _dir, project -> project end)
  end

  def modules(program) do
    program
    |> analyze()
    |> Map.fetch!(:modules)
    |> Normalize.modules()
  end

  def call_graph(program), do: analyze(program).call_graph

  def call_edges(program) do
    program
    |> call_graph()
    |> Graph.edges()
    |> Normalize.call_edges()
  end

  def effects(program) do
    program
    |> analyze()
    |> Map.fetch!(:modules)
    |> Enum.flat_map(fn {module, sdg} -> module_effects(module, sdg) end)
    |> MapSet.new()
  end

  def variable_names(program) do
    program
    |> analyze()
    |> all_nodes()
    |> Enum.filter(&(&1.type == :var))
    |> Enum.map(& &1.meta[:name])
    |> MapSet.new()
  end

  def data_edge_labels(program) do
    program
    |> analyze()
    |> Map.fetch!(:graph)
    |> Graph.edges()
    |> Enum.flat_map(fn
      %Graph.Edge{label: {:data, variable}} -> [variable]
      _edge -> []
    end)
    |> MapSet.new()
  end

  def call_present?(program, {module, function, arity}) do
    program
    |> analyze()
    |> all_nodes()
    |> Enum.any?(fn node -> call_match?(node, {module, function, arity}) end)
  end

  def branch_summary(program) do
    nodes = program |> analyze() |> all_nodes()

    %{
      case_nodes: Enum.filter(nodes, &(&1.type == :case)),
      fn_nodes: Enum.filter(nodes, &(&1.type == :fn)),
      clauses: Enum.filter(nodes, &(&1.type == :clause)),
      calls: Enum.filter(nodes, &(&1.type == :call)),
      functions: Enum.filter(nodes, &(&1.type == :function_def))
    }
  end

  def node_types(program) do
    program
    |> analyze()
    |> all_nodes()
    |> Enum.frequencies_by(& &1.type)
  end

  def function_defs(program) do
    program
    |> analyze()
    |> all_nodes()
    |> Enum.filter(&(&1.type == :function_def))
    |> Enum.map(fn node -> {node.meta[:name], node.meta[:arity]} end)
    |> MapSet.new()
  end

  defp call_match?(node, {module, function, arity}) do
    node.type == :call and node.meta[:module] == module and node.meta[:function] == function and
      node.meta[:arity] == arity
  end

  defp all_nodes(project) do
    project.modules
    |> Map.values()
    |> Enum.flat_map(fn sdg -> Map.values(sdg.nodes) end)
  end

  defp module_effects(module, sdg) do
    sdg.nodes
    |> Map.values()
    |> Enum.filter(&(&1.type == :function_def))
    |> Enum.flat_map(fn function_node -> function_effects(module, function_node) end)
  end

  defp function_effects(module, function_node) do
    function = {module, function_node.meta[:name], function_node.meta[:arity]}

    effects =
      function_node
      |> flatten_node()
      |> Enum.map(&Reach.Effects.classify/1)
      |> Enum.reject(&(&1 == :pure))
      |> Enum.uniq()

    case effects do
      [] -> [{function, :pure}]
      effects -> Enum.map(effects, &{function, &1})
    end
  end

  defp flatten_node(node), do: [node | Enum.flat_map(node.children, &flatten_node/1)]
end
