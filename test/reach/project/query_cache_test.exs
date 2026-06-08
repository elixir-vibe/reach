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
