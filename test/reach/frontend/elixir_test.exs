defmodule Reach.Frontend.ElixirTest do
  use ExUnit.Case, async: true

  alias Reach.Frontend.Elixir, as: ElixirFrontend
  alias Reach.IR
  alias Reach.IR.Node

  test "suppresses parser warnings while parsing source" do
    source = "а = 1\na = 2\n{а, a}"

    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert {:ok, _nodes} =
                 ElixirFrontend.parse(source, file: "deps/old_hex/lib/old.ex")
      end)

    assert output == ""
  end

  test "parses pipe-shaped macro heads without crashing" do
    source = """
    defmodule Sample do
      defmacro {input1, input2} |> {transform1, transform2} do
        quote do
          {unquote(input1), unquote(transform1), unquote(input2), unquote(transform2)}
        end
      end
    end
    """

    assert {:ok, [_node]} = ElixirFrontend.parse(source, file: "sample.ex")
  end

  test "does not treat quoted definitions as definitions in the surrounding module" do
    source = """
    defmodule Vibe.TUI do
      defp render_ast(block) do
        quote do
          def render(assigns), do: unquote(block)
        end
      end
    end
    """

    assert {:ok, [module]} = ElixirFrontend.parse(source, file: "sample.ex")

    functions =
      module
      |> IR.all_nodes()
      |> Enum.filter(&(&1.type == :function_def))
      |> Enum.map(& &1.meta.name)

    assert functions == [:render_ast]
  end

  test "assigns modules to functions inside defprotocol" do
    source = """
    defprotocol Vibe.Markdown do
      def to_markdown(term)
    end
    """

    assert {:ok, [module]} = ElixirFrontend.parse(source, file: "sample.ex")
    assert module.type == :module_def
    assert module.meta.name == Vibe.Markdown

    function = module |> IR.all_nodes() |> Enum.find(&(&1.type == :function_def))
    assert function.meta.module == Vibe.Markdown
    assert function.meta.name == :to_markdown
  end

  test "assigns modules to functions inside defimpl" do
    source = """
    defimpl Vibe.Markdown, for: Vibe.Image do
      def to_markdown(image), do: inspect(image)
    end
    """

    assert {:ok, [module]} = ElixirFrontend.parse(source, file: "sample.ex")
    assert module.type == :module_def
    assert module.meta.name == Vibe.Markdown.Vibe.Image

    function = module |> IR.all_nodes() |> Enum.find(&(&1.type == :function_def))
    assert function.meta.module == Vibe.Markdown.Vibe.Image
    assert function.meta.name == :to_markdown
  end

  test "expands nested defmodule names relative to the parent module" do
    source = """
    defmodule Vibe.UI.Block do
      defmodule Overlay do
        def new, do: %__MODULE__{}
      end
    end
    """

    assert {:ok, [parent]} = ElixirFrontend.parse(source, file: "sample.ex")

    nested =
      parent
      |> IR.all_nodes()
      |> Enum.find(&(&1.type == :module_def and &1.meta.name != Vibe.UI.Block))

    assert nested.meta.name == Vibe.UI.Block.Overlay
  end

  test "expands multi-part nested defmodule names relative to the parent module" do
    source = """
    defmodule Vibe.UI do
      defmodule Block.Overlay do
        def new, do: %__MODULE__{}
      end
    end
    """

    assert {:ok, [parent]} = ElixirFrontend.parse(source, file: "sample.ex")

    nested =
      parent
      |> IR.all_nodes()
      |> Enum.find(&(&1.type == :module_def and &1.meta.name != Vibe.UI))

    function = nested |> IR.all_nodes() |> Enum.find(&(&1.type == :function_def))

    assert nested.meta.name == Vibe.UI.Block.Overlay
    assert function.meta.module == Vibe.UI.Block.Overlay
  end

  describe "literals" do
    test "integer" do
      [node] = IR.from_string!("42")
      assert %Node{type: :literal, meta: %{value: 42}} = node
    end

    test "float" do
      [node] = IR.from_string!("3.14")
      assert %Node{type: :literal, meta: %{value: 3.14}} = node
    end

    test "string" do
      [node] = IR.from_string!(~s("hello"))
      assert %Node{type: :literal, meta: %{value: "hello"}} = node
    end

    test "atom" do
      [node] = IR.from_string!(":ok")
      assert %Node{type: :literal, meta: %{value: :ok}} = node
    end

    test "boolean" do
      [node] = IR.from_string!("true")
      assert %Node{type: :literal, meta: %{value: true}} = node
    end

    test "nil" do
      [node] = IR.from_string!("nil")
      assert %Node{type: :literal, meta: %{value: nil}} = node
    end
  end

  describe "variables" do
    test "simple variable" do
      [node] = IR.from_string!("x")
      assert %Node{type: :var, meta: %{name: :x}} = node
    end

    test "preserves variable name" do
      [node] = IR.from_string!("my_var")
      assert %Node{type: :var, meta: %{name: :my_var}} = node
    end
  end

  describe "match operator" do
    test "simple assignment" do
      [node] = IR.from_string!("x = 1")
      assert %Node{type: :match, children: [left, right]} = node
      assert %Node{type: :var, meta: %{name: :x}} = left
      assert %Node{type: :literal, meta: %{value: 1}} = right
    end

    test "pattern match with tuple" do
      [node] = IR.from_string!("{a, b} = foo()")
      assert %Node{type: :match} = node
      [tuple, call] = node.children
      assert %Node{type: :tuple} = tuple
      assert %Node{type: :call, meta: %{function: :foo}} = call
    end
  end

  describe "function calls" do
    test "local call" do
      [node] = IR.from_string!("foo(1, 2)")
      assert %Node{type: :call, meta: %{function: :foo, arity: 2, kind: :local}} = node
      assert length(node.children) == 2
    end

    test "remote call" do
      [node] = IR.from_string!("Enum.map(list, fun)")

      assert %Node{type: :call, meta: %{module: Enum, function: :map, arity: 2, kind: :remote}} =
               node
    end

    test "zero-arity call" do
      [node] = IR.from_string!("foo()")
      assert %Node{type: :call, meta: %{function: :foo, arity: 0}} = node
    end
  end

  describe "pipe operator desugaring" do
    test "simple pipe" do
      [node] = IR.from_string!("x |> foo()")
      assert %Node{type: :call, meta: %{function: :foo, desugared_from: :pipe}} = node
      assert length(node.children) == 1
    end

    test "pipe with args" do
      [node] = IR.from_string!("x |> foo(1)")
      assert %Node{type: :call, meta: %{function: :foo, desugared_from: :pipe}} = node
      assert length(node.children) == 2
    end

    test "pipe chain desugars into nested calls" do
      [node] = IR.from_string!("x |> foo() |> bar()")
      assert %Node{type: :call, meta: %{function: :bar, desugared_from: :pipe}} = node
      [inner] = node.children
      assert %Node{type: :call, meta: %{function: :foo}} = inner
    end
  end

  describe "if/unless desugaring" do
    test "if desugars to case with two branches" do
      [node] =
        IR.from_string!("""
        if x do
          1
        else
          2
        end
        """)

      assert %Node{type: :case, meta: %{desugared_from: :if}} = node
      [condition, true_clause, false_clause] = node.children
      assert %Node{type: :var, meta: %{name: :x}} = condition
      assert %Node{type: :clause, meta: %{kind: :true_branch}} = true_clause
      assert %Node{type: :clause, meta: %{kind: :false_branch}} = false_clause
    end

    test "unless desugars with swapped branches" do
      [node] =
        IR.from_string!("""
        unless x do
          1
        else
          2
        end
        """)

      assert %Node{type: :case, meta: %{desugared_from: :unless}} = node
      [_cond, true_clause, false_clause] = node.children
      # unless swaps: do-block becomes false branch
      assert %Node{type: :clause, meta: %{kind: :true_branch}} = true_clause
      assert %Node{type: :clause, meta: %{kind: :false_branch}} = false_clause
    end
  end

  describe "case" do
    test "case with multiple clauses" do
      [node] =
        IR.from_string!("""
        case x do
          :ok -> 1
          :error -> 2
          _ -> 3
        end
        """)

      assert %Node{type: :case} = node
      [expr | clauses] = node.children
      assert %Node{type: :var} = expr
      assert length(clauses) == 3

      Enum.each(clauses, fn clause ->
        assert %Node{type: :clause, meta: %{kind: :case_clause}} = clause
      end)
    end

    test "case clause indices" do
      [node] =
        IR.from_string!("""
        case x do
          1 -> :a
          2 -> :b
        end
        """)

      [_expr | clauses] = node.children
      assert [%{meta: %{index: 0}}, %{meta: %{index: 1}}] = clauses
    end
  end

  describe "cond" do
    test "cond desugars to case" do
      [node] =
        IR.from_string!("""
        cond do
          x > 0 -> :positive
          true -> :non_positive
        end
        """)

      assert %Node{type: :case, meta: %{desugared_from: :cond}} = node
      assert length(node.children) == 2
    end
  end

  describe "with" do
    test "translates bare literal clause without crashing" do
      [node] =
        IR.from_string!("""
        with {:ok, x} <- foo(),
             true do
          x
        end
        """)

      assert %Node{type: :case, meta: %{desugared_from: :with}} = node
    end
  end

  describe "function definitions" do
    test "simple def" do
      [node] =
        IR.from_string!("""
        def foo(x) do
          x + 1
        end
        """)

      assert %Node{type: :function_def, meta: %{name: :foo, arity: 1, kind: :def}} = node
      [clause] = node.children
      assert %Node{type: :clause, meta: %{kind: :function_clause}} = clause
    end

    test "def with guards" do
      [node] =
        IR.from_string!("""
        def foo(x) when is_integer(x) do
          x + 1
        end
        """)

      assert %Node{type: :function_def} = node
      [clause] = node.children
      guards = Enum.filter(clause.children, &(&1.type == :guard))
      assert length(guards) == 1
    end

    test "defp" do
      [node] =
        IR.from_string!("""
        defp bar(x), do: x
        """)

      assert %Node{type: :function_def, meta: %{kind: :defp}} = node
    end
  end

  describe "try" do
    test "try/rescue" do
      [node] =
        IR.from_string!("""
        try do
          risky()
        rescue
          e in RuntimeError -> handle(e)
        end
        """)

      assert %Node{type: :try} = node
      rescue_nodes = Enum.filter(node.children, &(&1.type == :rescue))
      assert length(rescue_nodes) == 1
    end
  end

  describe "receive" do
    test "receive with timeout" do
      [node] =
        IR.from_string!("""
        receive do
          {:msg, data} -> data
        after
          5000 -> :timeout
        end
        """)

      assert %Node{type: :receive} = node
      clauses = node.children
      receive_clauses = Enum.filter(clauses, &(&1.meta[:kind] == :receive_clause))
      timeout_clauses = Enum.filter(clauses, &(&1.meta[:kind] == :timeout_clause))
      assert length(receive_clauses) == 1
      assert length(timeout_clauses) == 1
    end
  end

  describe "anonymous functions" do
    test "fn with single clause" do
      [node] = IR.from_string!("fn x -> x + 1 end")
      assert %Node{type: :fn} = node
      assert length(node.children) == 1
      [clause] = node.children
      assert %Node{type: :clause, meta: %{kind: :fn_clause}} = clause
    end

    test "fn with multiple clauses" do
      [node] =
        IR.from_string!("""
        fn
          :ok -> 1
          :error -> 2
        end
        """)

      assert %Node{type: :fn} = node
      assert length(node.children) == 2
    end
  end

  describe "for comprehension" do
    test "simple for" do
      [node] =
        IR.from_string!("""
        for x <- list do
          x * 2
        end
        """)

      assert %Node{type: :comprehension} = node
      generators = Enum.filter(node.children, &(&1.type == :generator))
      assert length(generators) == 1
    end

    test "for with filter" do
      [node] =
        IR.from_string!("""
        for x <- list, x > 0 do
          x
        end
        """)

      assert %Node{type: :comprehension} = node
      filters = Enum.filter(node.children, &(&1.type == :filter))
      assert length(filters) == 1
    end
  end

  describe "data structures" do
    test "tuple" do
      [node] = IR.from_string!("{1, 2, 3}")
      assert %Node{type: :tuple} = node
      assert length(node.children) == 3
    end

    test "two-element tuple" do
      [node] = IR.from_string!("{:ok, 1}")
      assert %Node{type: :tuple} = node
      assert length(node.children) == 2
    end

    test "list" do
      [node] = IR.from_string!("[1, 2, 3]")
      assert %Node{type: :list} = node
      assert length(node.children) == 3
    end

    test "cons cell" do
      [node] = IR.from_string!("[head | tail]")
      assert %Node{type: :cons} = node
      assert length(node.children) == 2
    end

    test "map" do
      [node] = IR.from_string!("%{a: 1, b: 2}")
      assert %Node{type: :map} = node
      assert length(node.children) == 2
    end

    test "struct" do
      [node] = IR.from_string!("%User{name: \"Alice\"}")
      assert %Node{type: :struct, meta: %{name: User}} = node
    end
  end

  describe "operators" do
    test "binary operator" do
      [node] = IR.from_string!("x + 1")
      assert %Node{type: :binary_op, meta: %{operator: :+}} = node
      assert length(node.children) == 2
    end

    test "unary operator" do
      [node] = IR.from_string!("not x")
      assert %Node{type: :unary_op, meta: %{operator: :not}} = node
    end

    test "comparison" do
      [node] = IR.from_string!("x > 0")
      assert %Node{type: :binary_op, meta: %{operator: :>}} = node
    end
  end

  describe "pin operator" do
    test "pin is a use, not a definition" do
      [node] = IR.from_string!("^x")
      assert %Node{type: :pin} = node
      [inner] = node.children
      assert %Node{type: :var, meta: %{name: :x}} = inner
    end
  end

  describe "block" do
    test "multi-expression block" do
      [node] =
        IR.from_string!("""
        (
          x = 1
          y = 2
          x + y
        )
        """)

      assert %Node{type: :block} = node
      assert length(node.children) == 3
    end
  end

  describe "capture operator" do
    test "&fun/arity produces fun_ref node" do
      [node] = IR.from_string!("&to_string/1")
      assert %Node{type: :call, meta: %{function: :to_string, arity: 1, kind: :fun_ref}} = node
    end

    test "&Mod.fun/arity produces fun_ref with module" do
      [node] = IR.from_string!("&Enum.map/2")

      assert %Node{type: :call, meta: %{module: Enum, function: :map, arity: 2, kind: :fun_ref}} =
               node
    end

    test "&(&1 + 1) produces fn node" do
      [node] = IR.from_string!("&(&1 + 1)")
      assert %Node{type: :fn, meta: %{kind: :capture}} = node
    end

    test "&(&1.field) produces fn node with call child" do
      [node] = IR.from_string!("&(&1.active)")
      assert %Node{type: :fn, meta: %{kind: :capture}} = node
    end
  end

  describe "dot access on variables" do
    test "result.field makes result a child var node" do
      [node] = IR.from_string!("result.issues")
      assert %Node{type: :call, meta: %{function: :issues}} = node
      [receiver] = node.children
      assert %Node{type: :var, meta: %{name: :result}} = receiver
    end

    test "map.key preserves variable as child" do
      [node] = IR.from_string!("user.name")
      assert %Node{type: :call} = node
      [receiver] = node.children
      assert %Node{type: :var, meta: %{name: :user}} = receiver
    end

    test "chained dot access: a.b.c" do
      [node] = IR.from_string!("a.b.c")
      assert %Node{type: :call, meta: %{function: :c}} = node
      all = IR.all_nodes(node)
      vars = Enum.filter(all, &(&1.type == :var and &1.meta[:name] == :a))
      assert vars != []
    end

    test "chained access result.stats.field preserves variable" do
      nodes = IR.from_string!("result = foo()\nresult.stats.time\n")
      all = IR.all_nodes(nodes)
      vars = Enum.filter(all, &(&1.type == :var and &1.meta[:name] == :result))
      assert length(vars) == 2
    end

    test "module call still resolves module name" do
      [node] = IR.from_string!("Enum.map(list, fun)")
      assert %Node{type: :call, meta: %{module: Enum}} = node
    end
  end

  describe "metaprogramming" do
    test "unquote in function head doesn't crash" do
      assert {:ok, _} =
               IR.from_string("""
               defmodule M do
                 defmacro __using__(_) do
                   quote do
                     def unquote(:my_func)(x), do: x
                   end
                 end
               end
               """)
    end

    test "module attribute @ doesn't crash" do
      [node] =
        IR.from_string!("""
        defmodule M do
          @moduledoc "hello"
        end
        """)

      assert %Node{type: :module_def} = node
    end

    test "use directive doesn't crash" do
      assert {:ok, _} =
               IR.from_string("""
               defmodule M do
                 use GenServer
               end
               """)
    end
  end

  describe "source spans" do
    test "preserves line and column" do
      [node] = IR.from_string!("x = 1")
      assert node.source_span != nil
      assert node.source_span.start_line == 1
      assert node.source_span.start_col >= 1
    end
  end

  describe "IR utilities" do
    test "all_nodes collects all nodes depth-first" do
      [root] = IR.from_string!("x = 1 + 2")
      all = IR.all_nodes(root)
      types = Enum.map(all, & &1.type)
      assert :match in types
      assert :var in types
      assert :binary_op in types
      assert :literal in types
    end

    test "unique IDs across all nodes" do
      nodes =
        IR.from_string!("""
        def foo(x, y) do
          z = x + y
          if z > 0 do
            z
          else
            -z
          end
        end
        """)

      all = IR.all_nodes(nodes)
      ids = Enum.map(all, & &1.id)
      assert ids == Enum.uniq(ids)
    end
  end

  describe "alias resolution" do
    test "simple alias resolves to full module" do
      nodes =
        IR.from_string!("""
        defmodule MyApp do
          alias Plausible.Ingestion.Event

          def test, do: Event.build()
        end
        """)

      calls =
        nodes
        |> IR.all_nodes()
        |> Enum.filter(&(&1.type == :call and &1.meta[:function] == :build))

      assert [call] = calls
      assert call.meta[:module] == Plausible.Ingestion.Event
    end

    test "alias with :as option" do
      nodes =
        IR.from_string!("""
        defmodule MyApp do
          alias Foo.Bar.Baz, as: B

          def test, do: B.run()
        end
        """)

      calls =
        nodes |> IR.all_nodes() |> Enum.filter(&(&1.type == :call and &1.meta[:function] == :run))

      assert [call] = calls
      assert call.meta[:module] == Foo.Bar.Baz
    end

    test "multi-alias with curly braces" do
      nodes =
        IR.from_string!("""
        defmodule MyApp do
          alias Plausible.Stats.{Query, QueryRunner, Filters}

          def test do
            Query.new()
            QueryRunner.run()
            Filters.parse()
          end
        end
        """)

      calls =
        nodes
        |> IR.all_nodes()
        |> Enum.filter(&(&1.type == :call and &1.meta[:kind] == :remote))
        |> Enum.reject(&(&1.meta[:function] in [:alias, :{}, :__aliases__]))

      modules = Enum.map(calls, & &1.meta[:module]) |> Enum.sort()
      assert Plausible.Stats.Filters in modules
      assert Plausible.Stats.Query in modules
      assert Plausible.Stats.QueryRunner in modules
    end

    test "fully qualified name still works" do
      nodes =
        IR.from_string!("""
        defmodule MyApp do
          alias Some.Other.Thing

          def test, do: Some.Other.Thing.call()
        end
        """)

      calls =
        nodes
        |> IR.all_nodes()
        |> Enum.filter(&(&1.type == :call and &1.meta[:function] == :call))

      assert [call] = calls
      assert call.meta[:module] == Some.Other.Thing
    end

    test "alias does not leak across modules" do
      nodes =
        IR.from_string!("""
        defmodule A do
          alias Foo.Bar
          def test, do: Bar.run()
        end

        defmodule B do
          def test, do: Bar.run()
        end
        """)

      calls =
        nodes |> IR.all_nodes() |> Enum.filter(&(&1.type == :call and &1.meta[:function] == :run))

      assert length(calls) == 2

      [call_a, call_b] = Enum.sort_by(calls, & &1.id)
      assert call_a.meta[:module] == Foo.Bar
      assert call_b.meta[:module] == Bar
    end
  end

  describe "import resolution" do
    test "import resolves local call to imported module" do
      nodes =
        IR.from_string!("""
        defmodule MyApp do
          import Enum, only: [map: 2]

          def test(list), do: map(list, &to_string/1)
        end
        """)

      calls =
        nodes
        |> IR.all_nodes()
        |> Enum.filter(
          &(&1.type == :call and &1.meta[:function] == :map and &1.meta[:arity] == 2)
        )

      assert [call] = calls
      assert call.meta[:module] == Enum
      assert call.meta[:kind] == :remote
    end

    test "non-imported call stays local" do
      nodes =
        IR.from_string!("""
        defmodule MyApp do
          import Enum, only: [map: 2]

          def test, do: my_func()
          defp my_func, do: :ok
        end
        """)

      calls =
        nodes
        |> IR.all_nodes()
        |> Enum.filter(&(&1.type == :call and &1.meta[:function] == :my_func))

      assert [call] = calls
      assert call.meta[:module] == nil
      assert call.meta[:kind] == :local
    end

    test "import does not leak across modules" do
      nodes =
        IR.from_string!("""
        defmodule A do
          import Enum
          def test, do: map([], &to_string/1)
        end

        defmodule B do
          def test, do: map([], &to_string/1)
        end
        """)

      calls =
        nodes
        |> IR.all_nodes()
        |> Enum.filter(
          &(&1.type == :call and &1.meta[:function] == :map and &1.meta[:arity] == 2)
        )

      assert length(calls) == 2
      [call_a, call_b] = Enum.sort_by(calls, & &1.id)
      assert call_a.meta[:module] == Enum
      assert call_b.meta[:module] == nil
    end
  end

  describe "field access" do
    test "var.field is classified as field_access" do
      nodes =
        IR.from_string!("""
        defmodule M do
          def test(socket), do: socket.assigns
        end
        """)

      calls =
        nodes
        |> IR.all_nodes()
        |> Enum.filter(&(&1.type == :call and &1.meta[:function] == :assigns))

      assert [call] = calls
      assert call.meta[:kind] == :field_access
    end

    test "chained field access" do
      nodes =
        IR.from_string!("""
        defmodule M do
          def test(socket), do: socket.assigns.user
        end
        """)

      calls =
        nodes
        |> IR.all_nodes()
        |> Enum.filter(&(&1.type == :call and &1.meta[:kind] == :field_access))

      assert length(calls) == 2
      fields = Enum.map(calls, & &1.meta[:function]) |> Enum.sort()
      assert fields == [:assigns, :user]
    end

    test "Module.function() is NOT field_access" do
      nodes =
        IR.from_string!("""
        defmodule M do
          def test, do: Map.get(%{}, :key)
        end
        """)

      calls =
        nodes |> IR.all_nodes() |> Enum.filter(&(&1.type == :call and &1.meta[:function] == :get))

      assert [call] = calls
      assert call.meta[:kind] == :remote
      assert call.meta[:module] == Map
    end

    test "field access is pure" do
      nodes =
        IR.from_string!("""
        defmodule M do
          def test(conn), do: conn.params
        end
        """)

      calls =
        nodes
        |> IR.all_nodes()
        |> Enum.filter(&(&1.type == :call and &1.meta[:function] == :params))

      assert [call] = calls
      assert Reach.Effects.classify(call) == :pure
    end
  end

  describe "compile-time classification" do
    test "@doc is pure" do
      nodes =
        IR.from_string!("""
        defmodule M do
          @doc "hello"
          def test, do: :ok
        end
        """)

      doc_calls =
        nodes |> IR.all_nodes() |> Enum.filter(&(&1.type == :call and &1.meta[:function] == :doc))

      assert [call] = doc_calls
      assert Reach.Effects.classify(call) == :pure
    end

    test "use is pure" do
      nodes =
        IR.from_string!("""
        defmodule M do
          use GenServer
        end
        """)

      use_calls =
        nodes |> IR.all_nodes() |> Enum.filter(&(&1.type == :call and &1.meta[:function] == :use))

      assert [call] = use_calls
      assert Reach.Effects.classify(call) == :pure
    end
  end
end
