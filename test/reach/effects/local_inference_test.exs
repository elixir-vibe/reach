defmodule Reach.Effects.LocalInferenceTest do
  use ExUnit.Case, async: false

  alias Reach.{Effects, Frontend}

  defmodule CompiledProjectModule do
    def unresolved(callback, value), do: callback.(value)
    def caller(callback, value), do: unresolved(callback, value)
  end

  defmodule NestedDependency do
    def double(value), do: value * 2
  end

  defmodule CompiledDependency do
    def first(value), do: value + 1
    def second(value), do: NestedDependency.double(value)
  end

  setup do
    for cache <- [:reach_classify_cache, :reach_dependency_effect_cache],
        :ets.whereis(cache) != :undefined do
      :ets.delete_all_objects(cache)
    end

    :ok
  end

  test "resolves local calls against their owning module" do
    project =
      project("""
      defmodule LocalPureEffects do
        def helper(value), do: value + 1
        def run(value), do: helper(value)
      end

      defmodule LocalWriteEffects do
        def helper(path), do: File.write(path, "data")
        def run(path), do: helper(path)
      end
      """)

    pure_call = local_call(project, LocalPureEffects, :helper)
    write_call = local_call(project, LocalWriteEffects, :helper)

    assert Effects.classify(pure_call, []) == :pure
    assert Effects.classify(write_call, []) == :write

    assert %{effect: :pure, source: :local_inference, confidence: :medium} =
             Effects.classify_with_provenance(pure_call, [])

    assert %{effect: :write, source: :local_inference, confidence: :medium} =
             Effects.classify_with_provenance(write_call, [])
  end

  test "does not infer project modules from compiled dependency code" do
    project("""
    defmodule Reach.Effects.LocalInferenceTest.CompiledProjectModule do
      def unresolved(callback, value), do: callback.(value)
      def caller(callback, value), do: unresolved(callback, value)
    end
    """)

    refute dependency_cached?(CompiledProjectModule)
  end

  test "batches effect inference for calls to the same dependency module" do
    Code.ensure_loaded!(Frontend.BEAM)
    :erlang.trace_pattern({Frontend.BEAM, :from_module, 2}, true, [:local, :call_count])

    on_exit(fn ->
      :erlang.trace_pattern({Frontend.BEAM, :from_module, 2}, false, [:local, :call_count])
    end)

    project("""
    defmodule DependencyBatchConsumer do
      def first(value), do: Reach.Effects.LocalInferenceTest.CompiledDependency.first(value)
      def second(value), do: Reach.Effects.LocalInferenceTest.CompiledDependency.second(value)
    end
    """)

    assert {:call_count, 1} =
             :erlang.trace_info({Frontend.BEAM, :from_module, 2}, :call_count)
  end

  test "effect-only classification skips unknown-reason module resolution" do
    :erlang.trace_pattern({Code, :ensure_loaded?, 1}, true, [:local, :call_count])

    on_exit(fn ->
      :erlang.trace_pattern({Code, :ensure_loaded?, 1}, false, [:local, :call_count])
    end)

    node = call_node("UnknownEffects.run()")

    assert Effects.classify(node, []) == :unknown
    assert {:call_count, 0} = :erlang.trace_info({Code, :ensure_loaded?, 1}, :call_count)

    assert %{effect: :unknown, reason: :unresolved_module} =
             Effects.classify_with_provenance(node, [])

    assert {:call_count, 1} = :erlang.trace_info({Code, :ensure_loaded?, 1}, :call_count)
  end

  test "continues fixed-point inference while each pass resolves new functions" do
    project =
      project("""
      defmodule LocalEffectChain do
        def first(value), do: second(value)
        def second(value), do: third(value)
        def third(value), do: value + 1
      end
      """)

    assert project
           |> local_call(LocalEffectChain, :second)
           |> Effects.classify([]) == :pure

    assert project
           |> local_call(LocalEffectChain, :third)
           |> Effects.classify([]) == :pure
  end

  test "caches generated arities for functions with default arguments" do
    project =
      project("""
      defmodule LocalDefaultEffects do
        def persist(path, contents \\\\ "data"), do: File.write(path, contents)
        def run(path), do: persist(path)
      end
      """)

    assert project
           |> local_call(LocalDefaultEffects, :persist)
           |> Effects.classify([]) == :write
  end

  test "captures are pure until an eager higher-order call executes them" do
    project =
      project("""
      defmodule LocalCallbackEffects do
        def callback, do: &File.read!/1
        def eager(paths), do: Enum.map(paths, &read/1)
        def lazy(paths), do: Stream.map(paths, &File.read!/1)
        defp read(path), do: File.read(path)
      end
      """)

    assert function_call_effect(project, LocalCallbackEffects, :callback) == :pure
    assert function_call_effect(project, LocalCallbackEffects, :eager) == :read
    assert function_call_effect(project, LocalCallbackEffects, :lazy) == :pure
  end

  test "resolves unique project modules referenced through macro-injected aliases" do
    project =
      project("""
      defmodule AliasNamespace.Target do
        def normalize(value), do: value
      end

      defmodule AliasProvider do
        defmacro __using__(_opts) do
          quote do
            alias AliasNamespace.Target
          end
        end
      end

      defmodule AliasConsumer do
        use AliasProvider
        def run(value), do: Target.normalize(value)
      end
      """)

    assert function_call_effect(project, AliasConsumer, :run) == :pure
  end

  test "infers effects from dependency BEAM code and default wrappers" do
    assert %{effect: :pure, source: :dependency_inference, confidence: :medium} =
             "Graph.add_vertex(graph, vertex)"
             |> call_node()
             |> Effects.classify_with_provenance([])

    assert %{effect: :pure, source: :dependency_inference, confidence: :medium} =
             "Graph.new()"
             |> call_node()
             |> Effects.classify_with_provenance([])
  end

  defp project(source) do
    path =
      Path.join(
        System.tmp_dir!(),
        "reach-local-effects-#{System.unique_integer([:positive])}.ex"
      )

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)

    Reach.Project.from_sources([path], plugins: [])
  end

  defp local_call(project, owner_module, function) do
    project.nodes
    |> Map.values()
    |> Enum.find(fn node ->
      node.type == :call and node.meta[:kind] == :local and
        node.meta[:owner_module] == owner_module and node.meta[:function] == function
    end)
  end

  defp function_call_effect(project, module, function) do
    function_def =
      Enum.find(Map.values(project.nodes), fn node ->
        node.type == :function_def and node.meta[:module] == module and
          node.meta[:name] == function
      end)

    node = %Reach.IR.Node{
      id: -1,
      type: :call,
      meta: %{module: module, function: function, arity: function_def.meta[:arity], kind: :remote}
    }

    Effects.classify(node, project.plugins)
  end

  defp call_node(source) do
    [node] = Reach.IR.from_string!(source, plugins: [])
    node
  end

  defp dependency_cached?(module) do
    :ets.whereis(:reach_dependency_effect_cache) != :undefined and
      :ets.member(:reach_dependency_effect_cache, module)
  end
end
