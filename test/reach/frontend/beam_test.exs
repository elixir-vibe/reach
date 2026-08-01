defmodule Reach.Frontend.BEAMTest do
  use ExUnit.Case, async: false

  alias Reach.Frontend.BEAM

  describe "compiled_to_graph/2" do
    test "captures macro-injected callbacks from use GenServer" do
      mod = :"ReachTestGS#{System.unique_integer([:positive])}"

      source = "defmodule #{mod} do
  use GenServer

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state, state}
end"

      {:ok, graph} = Reach.compiled_to_graph(source)
      funcs = Reach.nodes(graph, type: :function_def)
      func_names = Enum.map(funcs, & &1.meta[:name]) |> Enum.uniq()

      assert :init in func_names
      assert :handle_call in func_names
      assert :child_spec in func_names, "use GenServer should inject child_spec"
    end

    test "captures try/rescue inside macros" do
      mod = :"ReachTestTR#{System.unique_integer([:positive])}"

      source = "defmodule #{mod} do
  defmacrop safe(do: body) do
    quote do
      try do
        unquote(body)
      rescue
        e -> {:error, e}
      end
    end
  end

  def run(x) do
    safe do
      x + 1
    end
  end
end"

      {:ok, graph} = Reach.compiled_to_graph(source)
      all = Reach.nodes(graph)

      func_names =
        all
        |> Enum.filter(&(&1.type == :function_def))
        |> Enum.map(& &1.meta[:name])

      assert :run in func_names

      types = Enum.map(all, & &1.type) |> Enum.uniq()

      assert :try in types or :catch_clause in types,
             "expanded code should contain try/catch, got types: #{inspect(types)}"
    end
  end

  describe "module_to_graph/2" do
    test "analyzes a loaded module" do
      {:ok, graph} = Reach.module_to_graph(Access)
      funcs = Reach.nodes(graph, type: :function_def)
      func_names = Enum.map(funcs, & &1.meta[:name]) |> Enum.uniq()

      assert :fetch in func_names
      assert :get in func_names
    end

    test "selects a target function and its local dependencies" do
      assert {:ok, nodes} =
               BEAM.from_module(Graph,
                 functions: [new: 0],
                 max_functions: 10
               )

      functions = Enum.filter(nodes, &(&1.type == :function_def))
      function_ids = MapSet.new(functions, &{&1.meta[:name], &1.meta[:arity]})

      assert MapSet.member?(function_ids, {:new, 0})
      assert MapSet.member?(function_ids, {:new, 1})
      refute Enum.any?(functions, &(&1.meta[:name] == :add_vertex))
      assert Enum.all?(functions, &(&1.meta[:module] == Graph))
    end

    test "returns error for non-existing module" do
      assert {:error, :module_not_found} = Reach.module_to_graph(NonExistentModule12345)
    end
  end
end
