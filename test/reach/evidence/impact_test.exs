defmodule Reach.Evidence.ImpactTest do
  use ExUnit.Case, async: true

  alias Reach.Evidence.Impact
  alias Reach.Inspect.Impact, as: InspectImpact
  alias Reach.Project

  test "shares bounded caller traversal with target-local impact analysis" do
    target = {ImpactLeaf, :target, 1}
    middle = {ImpactMiddle, :middle, 1}
    root = {ImpactRoot, :run, 1}

    call_graph =
      Graph.new(type: :directed)
      |> Graph.add_vertex(target)
      |> Graph.add_vertex(middle)
      |> Graph.add_vertex(root)
      |> Graph.add_edge(middle, target)
      |> Graph.add_edge(root, middle)

    project = %Project{
      modules: %{},
      graph: Graph.new(type: :directed),
      nodes: %{},
      call_graph: call_graph
    }

    assert Impact.callers(project, target, 1) == [middle]
    assert Impact.callers(project, target, 2) == [middle, root]

    inspection = InspectImpact.analyze(project, target, 2)
    assert inspection.direct_callers == [%{id: middle}]
    assert inspection.transitive_callers == [%{id: root}]
  end
end
