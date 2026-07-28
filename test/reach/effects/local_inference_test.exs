defmodule Reach.Effects.LocalInferenceTest do
  use ExUnit.Case, async: false

  alias Reach.Effects

  setup do
    if :ets.whereis(:reach_classify_cache) != :undefined do
      :ets.delete_all_objects(:reach_classify_cache)
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
end
