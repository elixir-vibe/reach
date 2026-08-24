defmodule Reach.VisualizeTest do
  use ExUnit.Case, async: true

  describe "to_graph_json/2" do
    test "produces all three modes" do
      graph =
        Reach.string_to_graph!("""
        defmodule MyMod do
          def greet(name) do
            IO.puts(name)
          end
        end
        """)

      result = Reach.Visualize.to_graph_json(graph)

      assert is_list(result.control_flow)
      assert is_map(result.call_graph)
      assert is_map(result.data_flow)
    end

    test "control flow has modules with functions and blocks" do
      graph =
        Reach.string_to_graph!("""
        defmodule A do
          def f(x), do: x
        end
        """)

      %{control_flow: [mod | _]} = Reach.Visualize.to_graph_json(graph)

      assert mod.module =~ "A"
      assert [func | _] = mod.functions
      assert func.name == "f"
      assert func.arity == 1
      assert is_list(func.nodes)
      assert is_list(func.edges)
    end

    test "call graph has modules and edges" do
      graph =
        Reach.string_to_graph!("""
        defmodule B do
          def caller, do: callee()
          def callee, do: :ok
        end
        """)

      %{call_graph: cg} = Reach.Visualize.to_graph_json(graph)

      assert is_list(cg.modules)
      assert is_list(cg.edges)
      assert cg.modules != []
    end

    test "call graph preserves source modules and files across a project" do
      dir =
        Path.join(System.tmp_dir!(), "reach-call-graph-#{System.unique_integer([:positive])}")

      alpha_path = Path.join(dir, "alpha.ex")
      beta_path = Path.join(dir, "beta.ex")
      File.mkdir_p!(dir)

      File.write!(alpha_path, """
      defmodule CallGraphAlpha do
        def run(value) when is_binary(value), do: CallGraphBeta.consume(value)
      end
      """)

      File.write!(beta_path, """
      defmodule CallGraphBeta do
        def consume(value), do: String.length(value)
      end
      """)

      on_exit(fn -> File.rm_rf!(dir) end)

      project = Reach.Project.from_sources([alpha_path, beta_path], plugins: [])
      %{call_graph: call_graph} = Reach.Visualize.to_graph_json(project)

      assert MapSet.new(call_graph.edges, & &1.source) ==
               MapSet.new(["CallGraphAlpha.run/1", "CallGraphBeta.consume/1"])

      modules = Map.new(call_graph.modules, &{&1.name, &1})
      assert modules["CallGraphAlpha"].file == alpha_path
      assert modules["CallGraphBeta"].file == beta_path

      refute Enum.any?(
               call_graph.modules,
               &Enum.any?(&1.functions, fn f -> f.name == "is_binary/1" end)
             )
    end

    test "data flow has functions and edges" do
      graph =
        Reach.string_to_graph!("""
        defmodule C do
          def f(x), do: g(x)
          def g(y), do: y
        end
        """)

      %{data_flow: df} = Reach.Visualize.to_graph_json(graph)

      assert is_list(df.functions)
      assert is_list(df.edges)
      assert is_list(df.taint_paths)
    end

    test "handles dynamically named implementation modules" do
      graph =
        Reach.string_to_graph!("""
        for protocol <- [String.Chars] do
          defimpl protocol, for: URI do
            def to_string(value) do
              path = value.path
              path
            end
          end
        end
        """)

      assert {:ok, _payload} = graph |> Reach.Visualize.to_json() |> JSON.decode()
    end

    test "data flow nodes identify their owning function and source" do
      dir =
        Path.join(System.tmp_dir!(), "reach-data-flow-#{System.unique_integer([:positive])}")

      path = Path.join(dir, "owner.ex")
      File.mkdir_p!(dir)

      File.write!(path, """
      defmodule DataFlowOwner do
        def normalize(input) do
          normalized = String.trim(input)
          normalized
        end
      end
      """)

      on_exit(fn -> File.rm_rf!(dir) end)

      project = Reach.Project.from_sources([path], plugins: [])
      result = Reach.Visualize.to_graph_json(project)
      data_nodes = result.data_flow.functions

      assert data_nodes != []

      function_ids =
        result.control_flow
        |> Enum.flat_map(& &1.functions)
        |> MapSet.new(& &1.id)

      assert Enum.all?(data_nodes, fn node ->
               node.module == "DataFlowOwner" and
                 node.file == path and
                 node.function_id in function_ids and
                 is_binary(node.source_html) and node.source_html != ""
             end)
    end

    test "data flow excludes Erlang module attributes without a function owner" do
      dir =
        Path.join(
          System.tmp_dir!(),
          "reach-erlang-data-flow-#{System.unique_integer([:positive])}"
        )

      path = Path.join(dir, "owner.erl")
      File.mkdir_p!(dir)

      File.write!(path, """
      -module(data_flow_owner).
      -export([normalize/1]).
      -spec normalize(binary()) -> binary().
      normalize(Input) -> Normalized = Input, Normalized.
      """)

      on_exit(fn -> File.rm_rf!(dir) end)

      project = Reach.Project.from_sources([path], plugins: [])
      result = Reach.Visualize.to_graph_json(project)
      data_nodes = result.data_flow.functions

      assert data_nodes != []
      assert Enum.all?(data_nodes, &(&1.module == "data_flow_owner"))
      assert Enum.all?(data_nodes, &(is_binary(&1.function_id) and &1.function_id != ""))
      refute Enum.any?(data_nodes, &(&1.label =~ "export(...)" or &1.label =~ "spec(...)"))
    end
  end

  describe "to_json/2" do
    test "returns valid JSON string" do
      graph =
        Reach.string_to_graph!("""
        defmodule G do
          def f(x), do: x
        end
        """)

      json = Reach.Visualize.to_json(graph)
      assert is_binary(json)
      assert {:ok, parsed} = JSON.decode(json)
      assert is_list(parsed["control_flow"])
    end
  end

  describe "struct and map pattern rendering" do
    # Regression: the :map and :struct render_pattern clauses used to split
    # children with Enum.chunk_every(2), but the IR actually wraps each pair
    # in a :map_field node — so render_map_pair/1 was handed a single-element
    # list and raised FunctionClauseError for any pattern like %Date{year: y}.
    alias Reach.IR.Node
    alias Reach.Visualize.Helpers

    test "renders a struct pattern with a single field binding" do
      year_key = %Node{id: 1, type: :literal, meta: %{value: :year}}
      y_var = %Node{id: 2, type: :var, meta: %{name: :y}}
      field = %Node{id: 3, type: :map_field, children: [year_key, y_var]}
      struct_node = %Node{id: 4, type: :struct, meta: %{name: Date}, children: [field]}

      assert Helpers.render_pattern(struct_node) == "%Date{year: y}"
    end

    test "renders a struct pattern with multiple field bindings" do
      k1 = %Node{id: 1, type: :literal, meta: %{value: :a}}
      v1 = %Node{id: 2, type: :var, meta: %{name: :x}}
      k2 = %Node{id: 3, type: :literal, meta: %{value: :b}}
      v2 = %Node{id: 4, type: :var, meta: %{name: :y}}
      f1 = %Node{id: 5, type: :map_field, children: [k1, v1]}
      f2 = %Node{id: 6, type: :map_field, children: [k2, v2]}
      struct_node = %Node{id: 7, type: :struct, meta: %{name: MyApp.User}, children: [f1, f2]}

      assert Helpers.render_pattern(struct_node) == "%MyApp.User{a: x, b: y}"
    end

    test "renders a map pattern with field bindings" do
      k = %Node{id: 1, type: :literal, meta: %{value: :year}}
      v = %Node{id: 2, type: :var, meta: %{name: :y}}
      field = %Node{id: 3, type: :map_field, children: [k, v]}
      map_node = %Node{id: 4, type: :map, children: [field]}

      assert Helpers.render_pattern(map_node) == "%{year: y}"
    end

    test "to_graph_json does not crash on code with a struct pattern" do
      graph =
        Reach.string_to_graph!("""
        defmodule StructPattern do
          def test(value) do
            case value do
              %Date{year: y} -> y
              _ -> nil
            end
          end
        end
        """)

      assert %{control_flow: _} = Reach.Visualize.to_graph_json(graph)
    end

    test "to_json does not crash on code with a nested struct pattern" do
      graph =
        Reach.string_to_graph!("""
        defmodule NestedStructPattern do
          def test(value) do
            case value do
              {:ok, %Date{year: y}} -> y
              _ -> nil
            end
          end
        end
        """)

      assert is_binary(Reach.Visualize.to_json(graph))
    end
  end
end
