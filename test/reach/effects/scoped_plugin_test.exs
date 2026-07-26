defmodule Reach.Effects.ScopedPluginTest do
  use ExUnit.Case, async: false

  defmodule WritePlugin do
    @behaviour Reach.Plugin

    @impl true
    def analyze(_nodes, _opts), do: []

    @impl true
    def classify_effect(%{
          type: :call,
          meta: %{module: Reach.Test.Effects.SpecReturnService, function: :run}
        }),
        do: :write

    def classify_effect(%{type: :call, meta: %{module: ScopedService, function: :run}}),
      do: :write

    def classify_effect(_node), do: nil
  end

  setup do
    if :ets.whereis(:reach_classify_cache) != :undefined do
      :ets.delete_all_objects(:reach_classify_cache)
    end

    old = :persistent_term.get(:reach_effect_plugins, nil)
    :persistent_term.erase(:reach_effect_plugins)

    on_exit(fn ->
      if :ets.whereis(:reach_classify_cache) != :undefined do
        :ets.delete_all_objects(:reach_classify_cache)
      end

      if old,
        do: :persistent_term.put(:reach_effect_plugins, old),
        else: :persistent_term.erase(:reach_effect_plugins)
    end)

    :ok
  end

  test "explicit plugins control classification without leaking through the cache" do
    node = call_node("ScopedService.run()")

    assert Reach.Effects.classify(node, []) == :unknown
    assert Reach.Effects.classify(node, [WritePlugin]) == :write
    assert Reach.Effects.classify(node, []) == :unknown
  end

  test "plugins override effects inferred from dependency specs" do
    node = call_node("Reach.Test.Effects.SpecReturnService.run()")

    assert Reach.Effects.classify(node, []) == :pure
    assert Reach.Effects.classify(node, [WritePlugin]) == :write
  end

  test "local inferred effects are scoped by plugin list" do
    source = """
    defmodule ScopedExample do
      def run do
        ScopedService.run()
      end
    end

    defmodule ScopedCaller do
      def run do
        ScopedExample.run()
      end
    end
    """

    project_without_plugin = project(source, [])
    project_with_plugin = project(source, [WritePlugin])

    call_without_plugin = function_call(project_without_plugin)
    call_with_plugin = function_call(project_with_plugin)

    assert Reach.Effects.classify(call_without_plugin, project_without_plugin.plugins) == :unknown
    assert Reach.Effects.classify(call_with_plugin, project_with_plugin.plugins) == :write
    assert Reach.Effects.classify(call_without_plugin, project_without_plugin.plugins) == :unknown
  end

  defp call_node(source) do
    [node] = Reach.IR.from_string!(source)
    node
  end

  defp project(source, plugins) do
    path =
      Path.join(
        System.tmp_dir!(),
        "reach-effects-plugin-#{System.unique_integer([:positive])}.ex"
      )

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)
    Reach.Project.from_sources([path], plugins: plugins)
  end

  defp function_call(project) do
    project.nodes
    |> Map.values()
    |> Enum.find(
      &(&1.type == :call and &1.meta[:module] == ScopedExample and &1.meta[:function] == :run)
    )
  end
end
