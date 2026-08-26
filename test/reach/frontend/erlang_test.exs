defmodule Reach.Frontend.ErlangTest do
  use ExUnit.Case, async: true

  alias Reach.Check.Smells
  alias Reach.Frontend.Erlang
  alias Reach.IR
  alias Reach.IR.Counter

  defp parse!(source) do
    {:ok, nodes} = Erlang.parse_string(source)
    nodes
  end

  defp function_nodes(nodes) do
    Enum.filter(nodes, &(&1.type == :function_def))
  end

  describe "basic parsing" do
    test "parses module attribute" do
      nodes = parse!("-module(test).\n")
      mod_attr = Enum.find(nodes, &(&1.meta[:function] == :module))
      assert mod_attr != nil
      assert mod_attr.meta[:value] == :test
    end

    test "parses simple function" do
      nodes = parse!("-module(test).\nfoo(X) -> X + 1.\n")
      funcs = function_nodes(nodes)
      assert [func] = funcs
      assert func.meta[:module] == :test
      assert func.meta[:name] == :foo
      assert func.meta[:arity] == 1
    end

    test "uses a shared counter across Erlang source files" do
      counter = Counter.new()

      {:ok, first} = Erlang.parse_string("-module(first).\nrun(X) -> X.\n", counter: counter)
      {:ok, second} = Erlang.parse_string("-module(second).\nrun(X) -> X.\n", counter: counter)

      first_ids = first |> IR.all_nodes() |> MapSet.new(& &1.id)
      second_ids = second |> IR.all_nodes() |> MapSet.new(& &1.id)

      assert MapSet.disjoint?(first_ids, second_ids)
    end

    test "parses multi-clause function" do
      nodes =
        parse!("""
        -module(test).
        classify(X) when X > 0 -> positive;
        classify(0) -> zero;
        classify(_) -> negative.
        """)

      funcs = function_nodes(nodes)
      assert [func] = funcs
      assert func.meta[:name] == :classify
      assert length(func.children) == 3
    end
  end

  describe "expressions" do
    test "integer literal" do
      nodes = parse!("-module(test).\nfoo() -> 42.\n")
      all = IR.all_nodes(nodes)
      assert Enum.any?(all, &(&1.type == :literal and &1.meta[:value] == 42))
    end

    test "atom literal" do
      nodes = parse!("-module(test).\nfoo() -> ok.\n")
      all = IR.all_nodes(nodes)
      assert Enum.any?(all, &(&1.type == :literal and &1.meta[:value] == :ok))
    end

    test "variable" do
      nodes = parse!("-module(test).\nfoo(X) -> X.\n")
      all = IR.all_nodes(nodes)
      vars = Enum.filter(all, &(&1.type == :var and &1.meta[:name] == :X))
      assert length(vars) >= 2
    end

    test "tuple" do
      nodes = parse!("-module(test).\nfoo() -> {ok, 1}.\n")
      all = IR.all_nodes(nodes)
      assert Enum.any?(all, &(&1.type == :tuple))
    end

    test "cons cell / list" do
      nodes = parse!("-module(test).\nfoo() -> [1, 2, 3].\n")
      all = IR.all_nodes(nodes)
      assert Enum.any?(all, &(&1.type == :cons))
    end

    test "binary operator" do
      nodes = parse!("-module(test).\nfoo(X) -> X + 1.\n")
      all = IR.all_nodes(nodes)
      assert Enum.any?(all, &(&1.type == :binary_op and &1.meta[:operator] == :+))
    end

    test "match" do
      nodes = parse!("-module(test).\nfoo(X) -> Y = X + 1, Y.\n")
      all = IR.all_nodes(nodes)
      assert Enum.any?(all, &(&1.type == :match))
    end
  end

  describe "calls" do
    test "local call" do
      nodes = parse!("-module(test).\nfoo(X) -> bar(X).\n")
      all = IR.all_nodes(nodes)
      bar = Enum.find(all, &(&1.type == :call and &1.meta[:function] == :bar))
      assert bar != nil
      assert bar.meta[:kind] == :local
      assert bar.meta[:module] == :test
      assert bar.meta[:owner_module] == :test
    end

    test "remote call" do
      nodes = parse!("-module(test).\nfoo(X) -> lists:map(X, []).\n")
      all = IR.all_nodes(nodes)

      call =
        Enum.find(
          all,
          &(&1.type == :call and &1.meta[:module] == :lists and &1.meta[:function] == :map)
        )

      assert call != nil
      assert call.meta[:kind] == :remote
    end

    test "remote function reference normalizes abstract atom and integer forms" do
      nodes = parse!("-module(test).\nhandler() -> fun telemetry:handle_event/4.\n")

      fun_ref =
        nodes
        |> IR.all_nodes()
        |> Enum.find(&(&1.type == :call and &1.meta[:kind] == :fun_ref))

      assert fun_ref.meta[:module] == :telemetry
      assert fun_ref.meta[:function] == :handle_event
      assert fun_ref.meta[:arity] == 4
    end
  end

  describe "control flow" do
    test "case" do
      nodes =
        parse!("""
        -module(test).
        foo(X) ->
            case X of
                ok -> 1;
                error -> 2
            end.
        """)

      all = IR.all_nodes(nodes)
      assert Enum.any?(all, &(&1.type == :case))
    end

    test "try/catch/after" do
      nodes =
        parse!("""
        -module(test).
        foo() ->
            try
                risky()
            catch
                error:Reason -> {error, Reason}
            after
                cleanup()
            end.
        """)

      all = IR.all_nodes(nodes)
      assert Enum.any?(all, &(&1.type == :try))
      assert Enum.any?(all, &(&1.type == :catch_clause))
      assert Enum.any?(all, &(&1.type == :after))
    end

    test "receive with timeout" do
      nodes =
        parse!("""
        -module(test).
        foo() ->
            receive
                {msg, Data} -> Data;
                stop -> ok
            after
                5000 -> timeout
            end.
        """)

      all = IR.all_nodes(nodes)
      assert Enum.any?(all, &(&1.type == :receive))

      clauses = Enum.filter(all, &(&1.type == :clause))
      receive_clauses = Enum.filter(clauses, &(&1.meta[:kind] == :receive_clause))
      timeout_clauses = Enum.filter(clauses, &(&1.meta[:kind] == :timeout_clause))
      assert length(receive_clauses) == 2
      assert length(timeout_clauses) == 1
    end

    test "anonymous function" do
      nodes = parse!("-module(test).\nfoo() -> fun(X) -> X * 2 end.\n")
      all = IR.all_nodes(nodes)
      assert Enum.any?(all, &(&1.type == :fn))
    end

    test "guards" do
      nodes =
        parse!("""
        -module(test).
        foo(X) when is_integer(X), X > 0 -> positive.
        """)

      all = IR.all_nodes(nodes)
      assert Enum.any?(all, &(&1.type == :guard))
    end
  end

  describe "unique IDs" do
    test "all nodes have unique IDs" do
      nodes =
        parse!("""
        -module(test).
        -export([foo/1, bar/1]).
        foo(X) -> bar(X + 1).
        bar(Y) -> Y * 2.
        """)

      all = IR.all_nodes(nodes)
      ids = Enum.map(all, & &1.id)
      assert ids == Enum.uniq(ids)
    end
  end

  describe "integration with Reach API" do
    test "string_to_graph with language: :erlang" do
      {:ok, graph} =
        Reach.string_to_graph(
          """
          -module(test).
          foo(X) -> X + 1.
          bar(Y) -> foo(Y).
          """,
          language: :erlang
        )

      assert %Reach.SystemDependence{} = graph
      assert Reach.nodes(graph) != []
    end

    test "file_to_graph auto-detects .erl" do
      path =
        Path.join(System.tmp_dir!(), "reach_test_#{:erlang.unique_integer([:positive])}.erl")

      File.write!(path, "-module(test).\nfoo(X) -> X + 1.\n")

      try do
        {:ok, graph} = Reach.file_to_graph(path)
        assert Reach.nodes(graph) != []
      after
        File.rm(path)
      end
    end

    test "smell analysis handles Erlang function metadata" do
      path =
        Path.join(System.tmp_dir!(), "reach_smell_#{:erlang.unique_integer([:positive])}.erl")

      File.write!(path, "-module(smell_probe).\n-export([fix_client/1]).\nfix_client(X) -> X.\n")

      try do
        project = Reach.Project.from_sources([path])

        function =
          Enum.find(Map.values(project.nodes), fn node ->
            node.type == :function_def and node.meta[:name] == :fix_client
          end)

        assert function.meta[:module] == :smell_probe
        assert is_list(Smells.run(project, []))
      after
        File.rm(path)
      end
    end

    test "slicing works on Erlang code" do
      graph =
        Reach.string_to_graph!(
          """
          -module(test).
          foo(X) ->
              Y = X + 1,
              Y.
          """,
          language: :erlang
        )

      all = Reach.nodes(graph)
      plus = Enum.find(all, &(&1.type == :binary_op and &1.meta[:operator] == :+))

      if plus do
        slice = Reach.backward_slice(graph, plus.id)
        assert is_list(slice)
        assert slice != []
      end
    end

    test "call graph connects Erlang functions" do
      graph =
        Reach.string_to_graph!(
          """
          -module(test).
          foo(X) -> bar(X).
          bar(Y) -> Y + 1.
          """,
          language: :erlang
        )

      cg = Reach.call_graph(graph)
      edges = Graph.edges(cg)
      assert edges != []
    end
  end
end
