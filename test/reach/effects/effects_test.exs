defmodule Reach.EffectsTest do
  use ExUnit.Case, async: true

  alias Reach.{Effects, IR}

  defp node_for(source) do
    [node] = IR.from_string!(source)
    node
  end

  describe "classify" do
    test "literals are pure" do
      assert Effects.classify(node_for("42")) == :pure
      assert Effects.classify(node_for(":ok")) == :pure
      assert Effects.classify(node_for(~s("hello"))) == :pure
    end

    test "variables are pure" do
      assert Effects.classify(node_for("x")) == :pure
    end

    test "data structures are pure" do
      assert Effects.classify(node_for("{1, 2}")) == :pure
      assert Effects.classify(node_for("%{a: 1}")) == :pure
    end

    test "operators are pure" do
      assert Effects.classify(node_for("x + 1")) == :pure
      assert Effects.classify(node_for("not x")) == :pure
    end

    test "pure module calls are pure" do
      assert Effects.classify(node_for("Enum.map(list, fun)")) == :pure
      assert Effects.classify(node_for("Map.get(map, key)")) == :pure
      assert Effects.classify(node_for("String.upcase(s)")) == :pure
      assert Effects.classify(node_for("List.first(l)")) == :pure
      assert Effects.classify(node_for("match?(%{}, value)")) == :pure
    end

    test "IO calls are :io" do
      assert Effects.classify(node_for("IO.puts(x)")) == :io
    end

    test "File reads are :read, writes are :write" do
      assert Effects.classify(node_for("File.read(path)")) == :read
      assert Effects.classify(node_for("File.write(path, data)")) == :write
    end

    test "send calls are :send" do
      assert Effects.classify(node_for("GenServer.call(pid, msg)")) == :send
      assert Effects.classify(node_for("GenServer.cast(pid, msg)")) == :send
    end

    test "PubSub broadcasts are :send" do
      assert Effects.classify(node_for("Phoenix.PubSub.broadcast(server, topic, msg)")) == :send

      assert Effects.classify(node_for("Phoenix.PubSub.broadcast_from(server, from, topic, msg)")) ==
               :send

      assert Effects.classify(
               node_for("Phoenix.PubSub.broadcast_from!(server, from, topic, msg)")
             ) ==
               :send
    end

    test "Task.Supervisor.start_child is :send" do
      assert Effects.classify(node_for("Task.Supervisor.start_child(sup, fun)")) == :send
    end

    test "ETS writes are :write" do
      assert Effects.classify(node_for(":ets.insert(tab, val)")) == :write
      assert Effects.classify(node_for(":ets.delete(tab, key)")) == :write
    end

    test "ETS reads are :read" do
      assert Effects.classify(node_for(":ets.lookup(tab, key)")) == :read
    end

    test "process dict writes are :write" do
      assert Effects.classify(node_for("Process.put(key, val)")) == :write
    end

    test "process dict reads are :read" do
      assert Effects.classify(node_for("Process.get(key)")) == :read
    end

    test "raise is :exception" do
      node = node_for("raise \"boom\"")
      assert Effects.classify(node) == :exception
      assert Effects.classify(node_for("Mix.raise(\"boom\")")) == :exception
    end

    test "precise platform operations use built-in semantics" do
      assert Effects.classify(node_for("Code.ensure_loaded?(Example)")) == :read
      assert Effects.classify(node_for("Mix.shell()")) == :read
      assert Effects.classify(node_for("System.cmd(\"echo\", [])")) == :io
      assert Effects.classify(node_for("Module.concat([Example, Nested])")) == :pure
      assert Effects.classify(node_for("Module.split(Example.Nested)")) == :pure
    end

    test "taking a function reference is intrinsically pure" do
      assert %{effect: :pure, source: :intrinsic, confidence: :high} =
               Effects.classify_with_provenance(node_for("&File.write!/2"))
    end

    test "unknown calls default to :unknown" do
      assert Effects.classify(node_for("some_function(x)")) == :unknown
    end
  end

  describe "classification provenance" do
    test "reports intrinsic and built-in classifications" do
      assert %{effect: :pure, source: :intrinsic, confidence: :high} =
               Effects.classify_with_provenance(node_for("42"))

      assert %{effect: :io, source: :builtin, confidence: :high} =
               Effects.classify_with_provenance(node_for("IO.puts(value)"))
    end

    test "reports typespec-derived and unknown classifications" do
      assert %{effect: :pure, source: :typespec, confidence: :medium} =
               Effects.classify_with_provenance(node_for(":crypto.hash(:sha256, <<>>)"))

      assert %{
               effect: :unknown,
               source: :unknown,
               confidence: :low,
               reason: :unresolved_module
             } = Effects.classify_with_provenance(node_for("UnknownEffects.run()"), [])

      assert %{effect: :unknown, reason: :dynamic_dispatch} =
               Effects.classify_with_provenance(node_for("handler.(value)"), [])
    end
  end

  describe "pure?" do
    test "true for pure nodes" do
      assert Effects.pure?(node_for("42"))
      assert Effects.pure?(node_for("Enum.map(l, f)"))
    end

    test "false for impure nodes" do
      refute Effects.pure?(node_for("IO.puts(x)"))
      refute Effects.pure?(node_for(":ets.insert(t, v)"))
    end
  end

  describe "specific function effects" do
    test "Module.register_attribute is not pure" do
      node = node_for("Module.register_attribute(__MODULE__, :foo, accumulate: true)")
      refute Effects.pure?(node)
    end

    test "Enum.each is not pure" do
      node = node_for("Enum.each(list, &IO.puts/1)")
      refute Effects.pure?(node)
    end

    test "Enum.map is pure" do
      node = node_for("Enum.map(list, &to_string/1)")
      assert Effects.pure?(node)
    end
  end

  describe "type-aware inference from specs" do
    test "infers :pure from typespec for unknown module functions" do
      node = node_for(":crypto.hash(:sha256, <<>>)")
      assert Effects.classify(node) == :pure
    end

    test "does not infer :pure for functions returning :ok" do
      node = node_for("IO.puts(:hello)")
      refute Effects.classify(node) == :pure
    end
  end

  describe "conflicting?" do
    test "pure never conflicts" do
      refute Effects.conflicting?(:pure, :pure)
      refute Effects.conflicting?(:pure, :io)
      refute Effects.conflicting?(:pure, :write)
    end

    test "unknown conflicts with non-pure" do
      assert Effects.conflicting?(:unknown, :io)
      assert Effects.conflicting?(:unknown, :write)
      assert Effects.conflicting?(:unknown, :unknown)
      # pure never conflicts, even with unknown
      refute Effects.conflicting?(:unknown, :pure)
      refute Effects.conflicting?(:pure, :unknown)
    end

    test "write-write conflicts" do
      assert Effects.conflicting?(:write, :write)
    end

    test "write-read conflicts" do
      assert Effects.conflicting?(:write, :read)
      assert Effects.conflicting?(:read, :write)
    end

    test "io-io conflicts (ordering matters)" do
      assert Effects.conflicting?(:io, :io)
    end

    test "send-send conflicts (message ordering)" do
      assert Effects.conflicting?(:send, :send)
    end

    test "send-receive conflicts" do
      assert Effects.conflicting?(:send, :receive)
      assert Effects.conflicting?(:receive, :send)
    end

    test "read-read does not conflict" do
      refute Effects.conflicting?(:read, :read)
    end
  end

  describe "inferred type classification" do
    if Version.match?(System.version(), ">= 1.19.0") do
      test "Enum.map/2 is classified as pure via inferred types" do
        node = %IR.Node{
          type: :call,
          id: 0,
          children: [],
          meta: %{module: Enum, function: :map, arity: 2}
        }

        assert Effects.classify(node) == :pure
      end

      test "Enum.each/2 is not classified as pure" do
        node = %IR.Node{
          type: :call,
          id: 0,
          children: [],
          meta: %{module: Enum, function: :each, arity: 2}
        }

        assert Effects.classify(node) != :pure
      end

      test "String.trim/1 is classified as pure via inferred types" do
        node = %IR.Node{
          type: :call,
          id: 0,
          children: [],
          meta: %{module: String, function: :trim, arity: 1}
        }

        assert Effects.classify(node) == :pure
      end
    end

    test "classify_from_spec falls back gracefully for unknown modules" do
      node = %IR.Node{
        type: :call,
        id: 0,
        children: [],
        meta: %{module: NonExistentModule, function: :foo, arity: 0}
      }

      assert Effects.classify(node) == :unknown
    end
  end

  describe "File I/O" do
    test "reads are :read, writes are :write, unknown falls to :io" do
      assert Effects.classify(node_for("File.read(path)")) == :read
      assert Effects.classify(node_for("File.write(path, data)")) == :write
      assert Effects.classify(node_for("File.stream!(path)")) == :io
    end

    test "Erlang :file follows same pattern" do
      assert Effects.classify(node_for(":file.read_file(path)")) == :read
      assert Effects.classify(node_for(":file.write_file(path, data)")) == :write
    end
  end

  describe "dead code integration" do
    test "File.write! is not flagged as dead code" do
      graph =
        Reach.string_to_graph!("""
        def save(path, data) do
          File.write!(path, data)
          :ok
        end
        """)

      dead_fns =
        graph
        |> Reach.dead_code()
        |> Enum.map(& &1.meta[:function])

      refute :write! in dead_fns
    end

    test "File.read result used in pipeline is not dead" do
      graph =
        Reach.string_to_graph!("""
        def load(path) do
          path |> File.read!() |> JSON.decode!()
        end
        """)

      assert Reach.dead_code(graph) == []
    end
  end
end
