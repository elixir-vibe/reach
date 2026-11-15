defmodule Reach.CallGraphTest do
  use ExUnit.Case, async: true

  alias Reach.{CallGraph, IR}

  describe "build/2" do
    test "identifies function definitions" do
      nodes =
        IR.from_string!("""
        def foo(x), do: x
        def bar(y), do: y + 1
        """)

      graph = CallGraph.build(nodes, module: MyModule)
      vertices = Graph.vertices(graph) |> MapSet.new()

      assert {MyModule, :foo, 1} in vertices
      assert {MyModule, :bar, 1} in vertices
    end

    test "creates call edges between functions" do
      nodes =
        IR.from_string!("""
        def foo(x), do: bar(x)
        def bar(y), do: y + 1
        """)

      graph = CallGraph.build(nodes)
      edges = Graph.edges(graph)

      call_edges =
        Enum.filter(edges, fn e ->
          match?({:call, _}, e.label)
        end)

      assert call_edges != []
    end

    test "handles remote calls" do
      nodes =
        IR.from_string!("""
        def foo(x), do: Enum.map(x, &to_string/1)
        """)

      graph = CallGraph.build(nodes)
      vertices = Graph.vertices(graph) |> MapSet.new()

      assert {Enum, :map, 2} in vertices
    end

    test "handles module-scoped definitions" do
      nodes =
        IR.from_string!("""
        defmodule MyMod do
          def foo(x), do: bar(x)
          def bar(y), do: y
        end
        """)

      graph = CallGraph.build(nodes, module: MyMod)
      vertices = Graph.vertices(graph) |> MapSet.new()

      assert {MyMod, :foo, 1} in vertices
      assert {MyMod, :bar, 1} in vertices
    end

    test "attributes call edges to the calling module" do
      nodes =
        IR.from_string!("""
        defmodule MyMod do
          def foo(x), do: bar(x)
          def bar(y), do: y
        end
        """)

      graph = CallGraph.build(nodes, module: MyMod)

      assert {MyMod, :bar, 1} in Graph.out_neighbors(graph, {MyMod, :foo, 1})
    end

    test "uses the defmodule name when it differs from the module option" do
      nodes =
        IR.from_string!("""
        defmodule Real.Mod do
          def foo(x), do: Other.bar(x)
        end
        """)

      graph = CallGraph.build(nodes, module: PathDerived.Mod)

      assert {Other, :bar, 1} in Graph.out_neighbors(graph, {Real.Mod, :foo, 1})
    end
  end

  describe "find_enclosing_function/2" do
    test "finds the function containing a node" do
      nodes =
        IR.from_string!("""
        def foo(x) do
          x + 1
        end
        """)

      all = IR.all_nodes(nodes)
      plus_node = Enum.find(all, &(&1.type == :binary_op and &1.meta[:operator] == :+))

      if plus_node do
        func = CallGraph.find_enclosing_function(nodes, plus_node.id)
        assert func != nil
        assert elem(func, 1) == :foo
      end
    end
  end
end
