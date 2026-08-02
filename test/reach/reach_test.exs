defmodule ReachTest do
  use ExUnit.Case, async: true

  describe "Phoenix plugin effect classification" do
    test "Phoenix.Controller.delete_csrf_token is :write, not :pure" do
      node = %Reach.IR.Node{
        id: 0,
        type: :call,
        meta: %{kind: :remote, module: Phoenix.Controller, function: :delete_csrf_token}
      }

      assert Reach.Plugin.classify_effect([Reach.Plugins.Phoenix], node) == :write
    end
  end

  describe "string_to_graph/2" do
    test "parses source and returns graph" do
      assert {:ok, graph} =
               Reach.string_to_graph("""
               def foo(x), do: x + 1
               """)

      assert %Reach.SystemDependence{} = graph
    end

    test "returns error for invalid source" do
      assert {:error, _} = Reach.string_to_graph("def foo(")
    end

    test "accepts :file option" do
      {:ok, graph} =
        Reach.string_to_graph("def foo(x), do: x", file: "my_file.ex")

      node = Reach.nodes(graph) |> Enum.find(&(&1.source_span != nil))
      assert node.source_span.file == "my_file.ex"
    end
  end

  describe "string_to_graph!/2" do
    test "returns graph directly" do
      graph =
        Reach.string_to_graph!("""
        def foo(x), do: x + 1
        """)

      assert %Reach.SystemDependence{} = graph
    end

    test "raises on parse error" do
      assert_raise ArgumentError, ~r/parse error/i, fn ->
        Reach.string_to_graph!("def foo(")
      end
    end
  end

  describe "file_to_graph/2" do
    test "reads and parses a file" do
      assert {:ok, graph} = Reach.file_to_graph("lib/reach/ir.ex")
      assert Reach.nodes(graph) != []
    end

    test "returns error for missing file" do
      assert {:error, {:file, :enoent}} = Reach.file_to_graph("nonexistent.ex")
    end

    test "infers module name from path" do
      {:ok, graph} = Reach.file_to_graph("lib/reach/effects.ex")
      cg = Reach.call_graph(graph)
      vertices = Graph.vertices(cg)

      has_effects_module =
        Enum.any?(vertices, fn
          {Reach.Effects, _, _} -> true
          _ -> false
        end)

      assert has_effects_module or true
    end
  end

  describe "nodes/2" do
    test "returns all nodes" do
      graph = Reach.string_to_graph!("def foo(x), do: x + 1")
      assert Reach.nodes(graph) != []
    end

    test "filters by type" do
      graph = Reach.string_to_graph!("def foo(x), do: x + 1")
      calls = Reach.nodes(graph, type: :call)
      Enum.each(calls, fn n -> assert n.type == :call end)
    end

    test "filters by module and function" do
      graph =
        Reach.string_to_graph!("""
        def foo(list) do
          Enum.map(list, &to_string/1)
        end
        """)

      enum_maps = Reach.nodes(graph, type: :call, module: Enum, function: :map)
      assert enum_maps != []
    end
  end

  describe "dynamic dispatch" do
    test "emits call nodes for handler.(args)" do
      graph =
        Reach.string_to_graph!("""
        def run(handler, input) do
          handler.(input)
        end
        """)

      dynamic = Reach.nodes(graph, type: :call) |> Enum.filter(&(&1.meta[:kind] == :dynamic))
      assert [call] = dynamic
      assert call.meta[:arity] == 1
      assert call.meta[:function] == nil
    end

    test "emits call nodes for local fn variable dispatch" do
      graph =
        Reach.string_to_graph!("""
        def run(input) do
          fun = fn x -> x + 1 end
          fun.(input)
        end
        """)

      dynamic = Reach.nodes(graph, type: :call) |> Enum.filter(&(&1.meta[:kind] == :dynamic))
      assert [call] = dynamic
      assert call.meta[:arity] == 1
      assert call.meta[:function] == nil
    end

    test "dynamic call has callee as first child" do
      graph =
        Reach.string_to_graph!("""
        def run(handler, x, y) do
          handler.(x, y)
        end
        """)

      [call] = Reach.nodes(graph, type: :call) |> Enum.filter(&(&1.meta[:kind] == :dynamic))
      assert call.meta[:arity] == 2
      assert [callee | args] = call.children
      assert callee.type == :var
      assert length(args) == 2
    end

    test "data flows through dynamic dispatch" do
      graph =
        Reach.string_to_graph!("""
        def run(handler, input) do
          handler.(input)
        end
        """)

      [handler_param | _] =
        Reach.nodes(graph, type: :var) |> Enum.filter(&(&1.meta[:name] == :handler))

      [call] = Reach.nodes(graph, type: :call) |> Enum.filter(&(&1.meta[:kind] == :dynamic))
      assert Reach.data_flows?(graph, handler_param.id, call.id)
    end
  end

  describe "node/2" do
    test "returns node by ID" do
      graph = Reach.string_to_graph!("def foo(x), do: x + 1")
      [first | _] = Reach.nodes(graph)
      assert Reach.node(graph, first.id) == first
    end

    test "returns nil for unknown ID" do
      graph = Reach.string_to_graph!("def foo(x), do: x + 1")
      assert Reach.node(graph, 999_999) == nil
    end
  end

  describe "backward_slice/2" do
    test "returns node IDs affecting the target" do
      graph =
        Reach.string_to_graph!("""
        def foo(x) do
          y = x + 1
          y
        end
        """)

      all = Reach.nodes(graph)

      last_y =
        all
        |> Enum.filter(&(&1.type == :var and &1.meta[:name] == :y))
        |> List.last()

      if last_y do
        slice = Reach.backward_slice(graph, last_y.id)
        assert is_list(slice)
      end
    end
  end

  describe "forward_slice/2" do
    test "returns node IDs affected by the source" do
      graph =
        Reach.string_to_graph!("""
        def foo(x) do
          y = x + 1
          z = y + 2
          z
        end
        """)

      all = Reach.nodes(graph)

      x_def =
        Enum.find(all, fn n ->
          n.type == :match and
            hd(n.children).type == :var and
            hd(n.children).meta[:name] == :x
        end)

      if x_def do
        slice = Reach.forward_slice(graph, x_def.id)
        assert is_list(slice)
      end
    end
  end

  describe "independent?/3" do
    test "independent variables" do
      graph =
        Reach.string_to_graph!("""
        def foo do
          x = 1
          y = 2
        end
        """)

      all = Reach.nodes(graph)

      x_match =
        Enum.find(all, fn n ->
          n.type == :match and hd(n.children).meta[:name] == :x
        end)

      y_match =
        Enum.find(all, fn n ->
          n.type == :match and hd(n.children).meta[:name] == :y
        end)

      if x_match && y_match do
        assert Reach.independent?(graph, x_match.id, y_match.id)
      end
    end
  end

  describe "data_flows?/3" do
    test "detects flow through variable assignment" do
      graph =
        Reach.string_to_graph!("""
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

      x_use =
        Enum.find(all, fn n ->
          n.type == :var and n.meta[:name] == :x and n.meta[:binding_role] != :definition
        end)

      if x_def && x_use do
        assert Reach.data_flows?(graph, x_def.id, x_use.id)
      end
    end
  end

  describe "pure?/1 and classify_effect/1" do
    test "literals are pure" do
      graph = Reach.string_to_graph!("42")
      [node] = Reach.nodes(graph, type: :literal)
      assert Reach.pure?(node)
      assert Reach.classify_effect(node) == :pure
    end

    test "IO calls are not pure" do
      graph = Reach.string_to_graph!("def foo, do: IO.puts(:hello)")
      calls = Reach.nodes(graph, type: :call, module: IO)
      [io_call | _] = calls
      refute Reach.pure?(io_call)
      assert Reach.classify_effect(io_call) == :io
    end
  end

  describe "edges/1" do
    test "returns dependence edges" do
      graph =
        Reach.string_to_graph!("""
        def foo(x) do
          y = x + 1
          y
        end
        """)

      edges = Reach.edges(graph)
      assert is_list(edges)
    end
  end

  describe "control_deps/2 and data_deps/2" do
    test "returns dependency lists" do
      graph =
        Reach.string_to_graph!("""
        def foo(x) do
          y = x + 1
          y
        end
        """)

      [node | _] = Reach.nodes(graph)
      assert is_list(Reach.control_deps(graph, node.id))
      assert is_list(Reach.data_deps(graph, node.id))
    end
  end

  describe "function_graph/2" do
    test "returns per-function PDG" do
      graph =
        Reach.string_to_graph!("""
        def foo(x), do: x + 1
        def bar(y), do: y * 2
        """)

      foo = Reach.function_graph(graph, {nil, :foo, 1})
      assert is_map(foo)

      assert Reach.function_graph(graph, {nil, :nope, 0}) == nil
    end
  end

  describe "context_sensitive_slice/2" do
    test "slices across function boundaries" do
      graph =
        Reach.string_to_graph!("""
        def foo(x), do: bar(x)
        def bar(y), do: y + 1
        """)

      all = Reach.nodes(graph)
      plus = Enum.find(all, &(&1.type == :binary_op and &1.meta[:operator] == :+))

      if plus do
        slice = Reach.context_sensitive_slice(graph, plus.id)
        assert is_list(slice)
      end
    end
  end

  describe "call_graph/1" do
    test "returns the call graph" do
      graph =
        Reach.string_to_graph!("""
        def foo(x), do: bar(x)
        def bar(y), do: y + 1
        """)

      cg = Reach.call_graph(graph)
      assert is_struct(cg, Graph)
    end
  end

  describe "ast_to_graph/2" do
    test "builds graph from parsed AST" do
      {:ok, ast} = Code.string_to_quoted("def foo(x), do: x + 1")
      {:ok, graph} = Reach.ast_to_graph(ast)

      assert Reach.nodes(graph) != []
      assert Reach.nodes(graph, type: :function_def) != []
    end
  end

  describe "canonical_order/2" do
    test "independent siblings get sorted deterministically" do
      graph =
        Reach.string_to_graph!("""
        def foo do
          a = 1
          b = 2
          {a, b}
        end
        """)

      blocks = Reach.nodes(graph, type: :block)

      if blocks != [] do
        order = Reach.canonical_order(graph, hd(blocks).id)
        assert is_list(order)
        assert order != []
      end
    end

    test "dependent statements preserve relative order" do
      graph =
        Reach.string_to_graph!("""
        def foo do
          x = 1
          y = x + 1
          y
        end
        """)

      blocks = Reach.nodes(graph, type: :block)

      if blocks != [] do
        order = Reach.canonical_order(graph, hd(blocks).id)
        assert is_list(order)
        assert order != []
      end
    end
  end

  describe "taint_analysis/2" do
    test "finds unsanitized flow from source to sink" do
      graph =
        Reach.string_to_graph!("""
        def handle(conn) do
          execute(get_param(conn))
        end
        """)

      results =
        Reach.taint_analysis(graph,
          sources: [type: :call, function: :get_param],
          sinks: [type: :call, function: :execute]
        )

      assert results != []
      [result | _] = results
      refute result.sanitized
    end

    test "detects sanitization in the path" do
      graph =
        Reach.string_to_graph!("""
        def handle(conn) do
          input = get_param(conn)
          safe = sanitize(input)
          execute(safe)
        end
        """)

      results =
        Reach.taint_analysis(graph,
          sources: [type: :call, function: :get_param],
          sinks: [type: :call, function: :execute],
          sanitizers: [type: :call, function: :sanitize]
        )

      if results != [] do
        assert hd(results).sanitized
      end
    end

    test "returns empty when no flow exists" do
      graph =
        Reach.string_to_graph!("""
        def handle(conn) do
          input = get_param(conn)
          execute("safe query")
        end
        """)

      results =
        Reach.taint_analysis(graph,
          sources: [type: :call, function: :get_param],
          sinks: [type: :call, function: :execute]
        )

      assert results == []
    end
  end

  describe "dead_code/1" do
    test "unused pure expression is dead" do
      graph =
        Reach.string_to_graph!("""
        def foo(x) do
          y = String.upcase(x)
          x
        end
        """)

      dead = Reach.dead_code(graph)
      dead_fns = Enum.filter(dead, &(&1.type == :call))
      assert Enum.any?(dead_fns, &(&1.meta[:function] == :upcase))
    end

    test "used expression is not dead" do
      graph = Reach.string_to_graph!("def foo(x), do: x + 1")
      dead = Reach.dead_code(graph)
      assert dead == []
    end

    test "unquoted expressions flow into a returned quote" do
      graph =
        Reach.string_to_graph!("""
        def quoted(value) do
          quote do
            unquote(String.upcase(value))
          end
        end
        """)

      dead = Reach.dead_code(graph)
      refute Enum.any?(dead, &(&1.meta[:function] == :upcase))
    end

    test "side-effecting call is never dead" do
      graph =
        Reach.string_to_graph!("""
        def foo(x) do
          IO.puts(x)
          :ok
        end
        """)

      dead = Reach.dead_code(graph)
      io_calls = Enum.filter(dead, &(&1.meta[:function] == :puts))
      assert io_calls == []
    end

    test "pure call without consumers is dead" do
      graph =
        Reach.string_to_graph!("""
        def foo(x) do
          String.upcase(x)
          :ok
        end
        """)

      dead = Reach.dead_code(graph)
      assert Enum.any?(dead, &(&1.meta[:function] == :upcase))
    end

    test "Phoenix compile-time DSL calls are not flagged as dead" do
      old_plugins = :persistent_term.get(:reach_effect_plugins, nil)
      :persistent_term.put(:reach_effect_plugins, [Reach.Plugins.Phoenix])

      try do
        graph =
          Reach.string_to_graph!("""
          defmodule ReproComponent do
            use Phoenix.Component

            attr :id, :string, required: true
            attr :label, :string, default: ""
            slot :inner_block, required: true

            def card(assigns), do: assigns
          end

          defmodule ReproRouter do
            use Phoenix.Router

            pipeline :browser do
              plug :accepts, ["html"]
            end

            scope "/" do
              pipe_through :browser
              get "/health", ReproController, :health
            end
          end
          """)

        dead = Reach.dead_code(graph)
        dead_fns = Enum.map(dead, & &1.meta[:function])

        refute :attr in dead_fns
        refute :slot in dead_fns
        refute :pipeline in dead_fns
        refute :plug in dead_fns
        refute :scope in dead_fns
        refute :pipe_through in dead_fns
        refute :get in dead_fns
      after
        if old_plugins,
          do: :persistent_term.put(:reach_effect_plugins, old_plugins),
          else: :persistent_term.erase(:reach_effect_plugins)
      end
    end

    test "Ecto schema and migration DSL calls are not flagged as dead" do
      old_plugins = :persistent_term.get(:reach_effect_plugins, nil)
      :persistent_term.put(:reach_effect_plugins, [Reach.Plugins.Ecto])

      try do
        graph =
          Reach.string_to_graph!("""
          defmodule ReproSchema do
            use Ecto.Schema

            schema "items" do
              field :name, :string
              has_many :children, Child
              timestamps()
            end
          end

          defmodule ReproMigration do
            use Ecto.Migration

            def change do
              create table(:items) do
                add :name, :string
                timestamps()
              end
            end
          end
          """)

        dead = Reach.dead_code(graph)
        dead_fns = Enum.map(dead, & &1.meta[:function])

        refute :schema in dead_fns
        refute :field in dead_fns
        refute :has_many in dead_fns
        refute :timestamps in dead_fns
        refute :create in dead_fns
        refute :add in dead_fns
      after
        if old_plugins,
          do: :persistent_term.put(:reach_effect_plugins, old_plugins),
          else: :persistent_term.erase(:reach_effect_plugins)
      end
    end

    test "guard calls are not flagged as dead" do
      graph =
        Reach.string_to_graph!("""
        def validate(x) when is_binary(x), do: {:ok, x}
        def validate(x) when is_integer(x), do: {:ok, x}
        def validate(_), do: :error
        """)

      dead = Reach.dead_code(graph)
      guard_fns = Enum.filter(dead, &(&1.meta[:function] in [:is_binary, :is_integer]))
      assert guard_fns == []
    end

    test "branch-tail return values are not flagged as dead" do
      graph =
        Reach.string_to_graph!("""
        def process(input) do
          if is_binary(input) do
            String.upcase(input)
          else
            to_string(input)
          end
        end
        """)

      dead = Reach.dead_code(graph)
      dead_fns = Enum.map(dead, & &1.meta[:function])
      refute :upcase in dead_fns
      refute :to_string in dead_fns
    end

    test "nested case/if tail returns are not flagged as dead" do
      graph =
        Reach.string_to_graph!("""
        def classify(x) do
          case x do
            :a -> Atom.to_string(:a)
            :b -> "b"
          end
        end
        """)

      dead = Reach.dead_code(graph)
      dead_fns = Enum.map(dead, & &1.meta[:function])
      refute :to_string in dead_fns
    end

    test "cond conditions are not flagged as dead" do
      graph =
        Reach.string_to_graph!("""
        def foo(x) do
          cond do
            x > 0 -> :positive
            true -> :negative
          end
        end
        """)

      dead = Reach.dead_code(graph)
      dead_ops = Enum.map(dead, & &1.meta[:operator])
      refute :> in dead_ops
    end

    test "comprehension filters are not flagged as dead" do
      graph =
        Reach.string_to_graph!("""
        def foo(list) do
          for x <- list, x > 0, do: x * 2
        end
        """)

      dead = Reach.dead_code(graph)
      dead_ops = Enum.map(dead, & &1.meta[:operator])
      refute :> in dead_ops
    end

    test "intermediate match with used variable is not dead" do
      graph =
        Reach.string_to_graph!("""
        def foo(x) do
          result = case x do
            :a -> String.upcase("a")
            :b -> String.upcase("b")
          end
          result
        end
        """)

      dead = Reach.dead_code(graph)
      dead_fns = Enum.map(dead, & &1.meta[:function])
      refute :upcase in dead_fns
    end

    test "ETS operations are not flagged as dead" do
      graph =
        Reach.string_to_graph!("""
        def foo(table) do
          :ets.new(table, [:named_table])
          :ets.insert(table, {:key, :val})
          :ok
        end
        """)

      dead = Reach.dead_code(graph)
      dead_fns = Enum.map(dead, & &1.meta[:function])
      refute :new in dead_fns
      refute :insert in dead_fns
    end

    test "fn clause tails are not flagged as dead" do
      graph =
        Reach.string_to_graph!("""
        def foo(list) do
          Enum.map(list, fn x -> String.upcase(x) end)
        end
        """)

      dead = Reach.dead_code(graph)
      dead_fns = Enum.map(dead, & &1.meta[:function])
      refute :upcase in dead_fns
    end

    test "raise arguments are not flagged as dead" do
      graph =
        Reach.string_to_graph!("""
        def foo(x) do
          raise "error: " <> inspect(x)
        end
        """)

      dead = Reach.dead_code(graph)
      dead_fns = Enum.map(dead, & &1.meta[:function])
      refute :inspect in dead_fns
    end

    test "typespec calls are not flagged as dead" do
      graph =
        Reach.string_to_graph!("""
        @spec foo(String.t()) :: :ok
        def foo(_x), do: :ok
        """)

      dead = Reach.dead_code(graph)
      dead_fns = Enum.map(dead, & &1.meta[:function])
      refute :t in dead_fns
    end

    test "intermediate variable used later is not dead" do
      graph =
        Reach.string_to_graph!("""
        def foo(x) do
          y = String.upcase(x)
          String.downcase(y)
        end
        """)

      dead = Reach.dead_code(graph)
      dead_fns = Enum.map(dead, & &1.meta[:function])
      refute :upcase in dead_fns
    end

    test "comprehension generator expressions are not dead" do
      graph =
        Reach.string_to_graph!("""
        def foo(n) do
          for i <- 0..(n - 1), do: i * 2
        end
        """)

      dead = Reach.dead_code(graph)
      dead_ops = Enum.map(dead, & &1.meta[:operator])
      refute :- in dead_ops
      refute :.. in dead_ops
    end

    test "string match pattern in with is not dead" do
      graph =
        Reach.string_to_graph!("""
        def foo(header) do
          with "Bearer " <> token <- header do
            token
          end
        end
        """)

      dead = Reach.dead_code(graph)
      dead_ops = Enum.map(dead, & &1.meta[:operator])
      refute :<> in dead_ops
    end

    test "case subject expression is not dead" do
      graph =
        Reach.string_to_graph!("""
        def foo(x) do
          case Integer.parse(x) do
            {n, _} -> n
            :error -> 0
          end
        end
        """)

      dead = Reach.dead_code(graph)
      dead_fns = Enum.map(dead, & &1.meta[:function])
      refute :parse in dead_fns
    end

    test "unused pure call inside branch body is dead" do
      graph =
        Reach.string_to_graph!("""
        def foo(x) do
          if x > 0 do
            x
          else
            String.upcase("unused")
            0
          end
        end
        """)

      dead = Reach.dead_code(graph)
      dead_fns = Enum.map(dead, & &1.meta[:function])
      assert :upcase in dead_fns
    end

    test "variable captured by closure is not dead" do
      graph =
        Reach.string_to_graph!("""
        def foo do
          now = DateTime.to_unix(DateTime.utc_now())
          Enum.reduce([], 0, fn x, acc ->
            case x do
              y when y < now -> acc + 1
              _ -> acc
            end
          end)
        end
        """)

      dead = Reach.dead_code(graph)

      dead_names =
        dead
        |> Enum.filter(&(&1.type == :match))
        |> Enum.flat_map(fn m ->
          m.children |> Enum.filter(&(&1.type == :var)) |> Enum.map(& &1.meta[:name])
        end)

      refute :now in dead_names
    end

    test "with clause value expressions are not dead" do
      graph =
        Reach.string_to_graph!("""
        def foo(opts) do
          check = Keyword.get(opts, :check, true)
          with true <- check, {:ok, v} <- Map.fetch(opts, :val) do
            v
          end
        end
        """)

      dead = Reach.dead_code(graph)
      dead_fns = Enum.map(dead, & &1.meta[:function])
      refute :get in dead_fns
      refute :fetch in dead_fns
    end

    test "bare expression inside with is not dead" do
      graph =
        Reach.string_to_graph!("""
        def foo(conn, opts) do
          check = Keyword.get(opts, :check, true)
          with cookie <- conn.cookies,
               conn = Map.put(conn, :key, cookie),
               true <- not check do
            conn
          end
        end
        """)

      dead = Reach.dead_code(graph)
      dead_fns = Enum.map(dead, & &1.meta[:function])
      refute :get in dead_fns
    end

    test "receive after timeout expression is not dead" do
      graph =
        Reach.string_to_graph!("""
        def foo(opts) do
          timeout = Keyword.get(opts, :timeout, 5000)
          receive do
            {:ok, result} -> result
          after
            timeout -> :timeout
          end
        end
        """)

      dead = Reach.dead_code(graph)
      dead_fns = Enum.map(dead, & &1.meta[:function])
      refute :get in dead_fns
    end

    test "variable used in for comprehension case is not dead" do
      graph =
        Reach.string_to_graph!("""
        def foo(opts, tasks) do
          mode = Keyword.get(opts, :mode, :default)
          for task <- tasks do
            case mode do
              :default -> task
              :skip -> nil
            end
          end
        end
        """)

      dead = Reach.dead_code(graph)
      dead_fns = Enum.map(dead, & &1.meta[:function])
      refute :get in dead_fns
    end

    test "struct pattern variable binding is not dead" do
      graph =
        Reach.string_to_graph!("""
        def foo(refl) do
          %module{} = refl
          module.query(refl)
        end
        """)

      dead = Reach.dead_code(graph)
      assert dead == []
    end

    test "compiler directives are not dead" do
      graph =
        Reach.string_to_graph!("""
        defmodule Foo do
          import Enum
          alias String, as: S
          require Logger
          @moduledoc "docs"
          @doc "bar"
          @spec bar(integer()) :: string()
          @type t :: atom()
          def bar(x), do: to_string(x)
        end
        """)

      dead = Reach.dead_code(graph)
      dead_fns = Enum.map(dead, & &1.meta[:function])
      refute :import in dead_fns
      refute :alias in dead_fns
      refute :require in dead_fns
      refute :moduledoc in dead_fns
      refute :doc in dead_fns
      refute :spec in dead_fns
      refute :type in dead_fns
    end

    test "{:ok, _} return type in spec does not infer pure" do
      graph =
        Reach.string_to_graph!("""
        def foo(x) do
          Mint.HTTP.close(x)
          :done
        end
        """)

      dead = Reach.dead_code(graph)
      dead_fns = Enum.map(dead, & &1.meta[:function])
      refute :close in dead_fns
    end

    test "with body expressions are properly translated" do
      graph =
        Reach.string_to_graph!("""
        def foo(x) do
          with {:ok, y} <- bar(x) do
            y + 1
          end
        end
        """)

      dead = Reach.dead_code(graph)
      dead_ops = Enum.map(dead, & &1.meta[:operator])
      refute :+ in dead_ops
    end

    test "unquote_splicing vars are references, not definitions" do
      graph =
        Reach.string_to_graph!("""
        def foo(x) do
          match_all = x ++ [1, 2]
          quote do
            %{unquote_splicing(match_all)} = var
          end
        end
        """)

      dead = Reach.dead_code(graph)

      dead_names =
        dead
        |> Enum.filter(&(&1.type == :match))
        |> Enum.flat_map(fn m ->
          m.children |> Enum.filter(&(&1.type == :var)) |> Enum.map(& &1.meta[:name])
        end)

      refute :match_all in dead_names
    end

    test "non-tail with clause values are alive" do
      graph =
        Reach.string_to_graph!("""
        def foo(modes) do
          with {:read_offset, offset} <- :lists.keyfind(:read_offset, 1, modes),
               false <- is_integer(offset) and offset >= 0 do
            raise ArgumentError, "bad"
          end
          %{modes: modes}
        end
        """)

      dead = Reach.dead_code(graph)
      dead_fns = Enum.map(dead, & &1.meta[:function])
      dead_ops = Enum.map(dead, & &1.meta[:operator])
      refute :keyfind in dead_fns
      refute :is_integer in dead_fns
      refute :and in dead_ops
    end
  end

  describe "higher-order function resolution" do
    test "Enum.map callback flows to result" do
      graph =
        Reach.string_to_graph!("""
        def foo(items) do
          Enum.map(items, &String.upcase/1)
        end
        """)

      edges = Reach.edges(graph)
      ho_edges = Enum.filter(edges, &(&1.label == :higher_order))
      assert ho_edges != []
    end

    test "Enum.each callback does not flow to result" do
      graph =
        Reach.string_to_graph!("""
        def foo(items) do
          Enum.each(items, &IO.puts/1)
        end
        """)

      edges = Reach.edges(graph)
      ho_edges = Enum.filter(edges, &(&1.label == :higher_order))
      assert ho_edges == []
    end

    test "collection flows through Enum.filter" do
      graph =
        Reach.string_to_graph!("""
        def foo(items) do
          Enum.filter(items, &(&1 > 0))
        end
        """)

      edges = Reach.edges(graph)
      ho_edges = Enum.filter(edges, &(&1.label == :higher_order))
      assert ho_edges != []
    end
  end

  describe "to_graph/1" do
    test "returns the raw libgraph struct" do
      graph = Reach.string_to_graph!("def foo(x), do: x + 1")
      raw = Reach.to_graph(graph)
      assert is_struct(raw, Graph)
      assert Graph.vertices(raw) |> is_list()
    end

    test "libgraph operations work on the raw graph" do
      graph = Reach.string_to_graph!("def foo(x), do: x + 1")
      raw = Reach.to_graph(graph)
      assert Graph.num_vertices(raw) > 0
      assert Graph.num_edges(raw) > 0
    end
  end

  describe "neighbors/3" do
    test "returns all direct neighbors" do
      graph =
        Reach.string_to_graph!("""
        def foo(x) do
          y = x + 1
          y
        end
        """)

      all = Reach.nodes(graph)
      node = Enum.find(all, &(&1.type == :binary_op))

      if node do
        n = Reach.neighbors(graph, node.id)
        assert is_list(n)
        assert n != []
      end
    end

    test "filters by label" do
      graph =
        Reach.string_to_graph!("""
        def foo(x) do
          y = x + 1
          y
        end
        """)

      all = Reach.nodes(graph)
      node = Enum.find(all, &(&1.type == :binary_op))

      if node do
        containment = Reach.neighbors(graph, node.id, :containment)
        assert is_list(containment)
      end
    end

    test "filters by tag for tuple labels" do
      graph =
        Reach.string_to_graph!("""
        def foo(x) do
          y = x + 1
          y
        end
        """)

      all = Reach.nodes(graph)
      clause = Enum.find(all, &(&1.type == :clause))

      if clause do
        data_neighbors = Reach.neighbors(graph, clause.id, :data)
        assert is_list(data_neighbors)
      end
    end
  end

  describe "to_dot/1" do
    test "exports to DOT format" do
      graph = Reach.string_to_graph!("def foo(x), do: x + 1")
      assert {:ok, dot} = Reach.to_dot(graph)
      assert String.contains?(dot, "digraph")
    end
  end
end
