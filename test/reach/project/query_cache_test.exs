defmodule Reach.Project.QueryCacheTest do
  use ExUnit.Case, async: true

  alias Reach.Project
  alias Reach.Project.Query

  test "function indexes do not leak between projects in the same process" do
    first = project_with("FirstOnly", "run")
    second = project_with("SecondOnly", "execute")

    assert Query.find_function(first, {FirstOnly, :run, 0})
    refute Query.find_function(first, {SecondOnly, :execute, 0})

    assert Query.find_function(second, {SecondOnly, :execute, 0})
    refute Query.find_function(second, {FirstOnly, :run, 0})
  end

  test "function_index is memoized within a process for the same project" do
    project = project_with("Memoized", "go")

    first = Query.function_index(project)
    second = Query.function_index(project)

    assert :erts_debug.same(first, second)
  end

  test "reset_cache invalidates the cached function index" do
    project = project_with("Resettable", "do_thing")

    first = Query.function_index(project)
    Query.reset_cache()
    second = Query.function_index(project)

    refute :erts_debug.same(first, second)
  end

  test "manually constructed projects bypass the cache" do
    project = project_with("Uncached", "act") |> Map.put(:cache_key, nil)

    first = Query.function_index(project)
    second = Query.function_index(project)

    refute :erts_debug.same(first, second)
  end

  test "updating project nodes invalidates the cached index" do
    project = project_with("Original", "original")
    replacement = project_with("Replacement", "replacement")

    assert Query.find_function(project, {Original, :original, 0})

    updated = %{project | nodes: replacement.nodes, call_graph: replacement.call_graph}

    assert Query.find_function(updated, {Replacement, :replacement, 0})
    refute Query.find_function(updated, {Original, :original, 0})
  end

  test "updating the call graph invalidates cached named modules" do
    project = project_with("OriginalGraph", "run")
    replacement = project_with("ReplacementGraph", "execute")

    assert Query.function_index(project).named_modules[{:run, 0}] == OriginalGraph

    updated = %{project | call_graph: replacement.call_graph}

    assert Query.function_index(updated).named_modules[{:execute, 0}] == ReplacementGraph
    refute Query.function_index(updated).named_modules[{:run, 0}]
  end

  defp project_with(module, function) do
    source = """
    defmodule #{module} do
      def #{function}, do: :ok
    end
    """

    path =
      Path.join(System.tmp_dir!(), "reach-query-cache-#{System.unique_integer([:positive])}.ex")

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)

    Project.from_sources([path], plugins: [])
  end
end
