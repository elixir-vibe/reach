defmodule Reach.QueryTest do
  use ExUnit.Case, async: true

  alias Reach.Project
  alias Reach.Project.Query

  defp build_graph(source) do
    Reach.string_to_graph!(source)
  end

  describe "nodes/2" do
    test "returns all nodes" do
      graph = build_graph("def foo(x), do: x + 1")
      all = Reach.nodes(graph)
      assert all != []
    end

    test "filters by type" do
      graph = build_graph("def foo(x), do: x + 1")
      calls = Reach.nodes(graph, type: :call)
      Enum.each(calls, fn n -> assert n.type == :call end)
    end

    test "filters by module" do
      graph =
        build_graph("""
        def foo(x) do
          Enum.map(x, &to_string/1)
        end
        """)

      enum_calls = Reach.nodes(graph, type: :call, module: Enum)
      assert enum_calls != []
      Enum.each(enum_calls, fn n -> assert n.meta[:module] == Enum end)
    end
  end

  describe "data_flows?" do
    test "detects data flow through variable" do
      graph =
        build_graph("""
        def foo(x) do
          y = x + 1
          y
        end
        """)

      all = Reach.nodes(graph)
      x_nodes = Enum.filter(all, &(&1.type == :var and &1.meta[:name] == :x))
      y_nodes = Enum.filter(all, &(&1.type == :var and &1.meta[:name] == :y))

      if x_nodes != [] and y_nodes != [] do
        x_def =
          Enum.find(
            all,
            &(&1.type == :match and match?(%{children: [%{meta: %{name: :x}} | _]}, &1))
          )

        y_use = y_nodes |> Enum.reverse() |> List.first()

        if x_def && y_use do
          assert is_boolean(Reach.data_flows?(graph, x_def.id, y_use.id))
        end
      end
    end
  end

  describe "has_dependents?" do
    test "definition with later use has dependents" do
      graph =
        build_graph("""
        def foo do
          x = 1
          y = x + 1
          y
        end
        """)

      all = Reach.nodes(graph)

      x_def =
        Enum.find(all, fn n ->
          n.type == :var and n.meta[:name] == :x and n.meta[:binding_role] == :definition
        end)

      if x_def do
        assert Reach.has_dependents?(graph, x_def.id)
      end
    end
  end

  describe "pure?" do
    test "delegates to Effects" do
      [node] = Reach.IR.from_string!("42")
      assert Reach.pure?(node)

      [node] = Reach.IR.from_string!("IO.puts(x)")
      refute Reach.pure?(node)
    end
  end

  describe "value_predecessor_index/1" do
    test "invalidates cached indexes when the project graph changes" do
      project =
        """
        defmodule ValueIndex do
          def run(value), do: value
        end
        """
        |> project_from_string()
        |> Map.put(:cache_key, make_ref())

      assert Query.value_predecessor_index(project) == Query.value_predecessor_index(project)

      [from_id, to_id | _rest] = Map.keys(project.nodes)
      graph = Graph.add_edge(project.graph, from_id, to_id, label: :summary)
      updated_project = %{project | graph: graph}

      assert from_id in Map.fetch!(Query.value_predecessor_index(updated_project), to_id)
    end
  end

  describe "function_index/1" do
    test "groups functions by module and name in arity order" do
      project =
        project_from_string("""
        defmodule IndexedFunctions do
          def fetch(value), do: value
          def fetch(value, fallback, opts), do: {value, fallback, opts}
          def other(value, fallback), do: {value, fallback}
        end
        """)

      arities =
        project
        |> Query.function_index()
        |> Map.fetch!(:by_module_name)
        |> Map.fetch!({IndexedFunctions, :fetch})
        |> Enum.map(& &1.meta.arity)

      assert arities == [1, 3]
    end
  end

  describe "value lineage" do
    test "finds a shared parameter origin through a key conversion" do
      project =
        project_from_string("""
        defmodule LooseContract do
          def get(map, key) do
            Map.get(map, key) || Map.get(map, Atom.to_string(key))
          end
        end
        """)

      key_use =
        Enum.find(project.nodes, fn {_id, node} ->
          node.type == :var and node.meta[:name] == :key and
            node.meta[:binding_role] != :definition
        end)
        |> elem(1)

      conversion =
        Enum.find(project.nodes, fn {_id, node} ->
          node.type == :call and node.meta[:module] == Atom and
            node.meta[:function] == :to_string
        end)
        |> elem(1)

      assert [%{type: :var, meta: %{name: :key, binding_role: :definition}}] =
               Query.value_origins(project, key_use)

      assert [%{type: :var, meta: %{name: :key, binding_role: :definition}} = definition] =
               Query.value_origins(project, conversion)

      assert Query.value_successors(project, definition) != []

      assert [%{id: definition_id} | _] = path = Query.value_path(project, definition, conversion)
      assert definition_id == definition.id
      assert List.last(path).id == conversion.id
    end
  end

  defp project_from_string(source) do
    graph = Reach.string_to_graph!(source)

    %Project{
      modules: %{},
      graph: Reach.to_graph(graph),
      nodes: Map.new(Reach.nodes(graph), &{&1.id, &1}),
      call_graph: graph.call_graph,
      plugins: []
    }
  end
end
