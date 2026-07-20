defmodule Reach.ProjectTest do
  use ExUnit.Case, async: false

  alias Reach.CLI.Project, as: CLIProject
  alias Reach.Project
  alias Reach.Project.Query

  @tmp_dir Path.join(
             System.tmp_dir!(),
             "reach_project_test_#{:erlang.unique_integer([:positive])}"
           )

  setup do
    File.mkdir_p!(Path.join(@tmp_dir, "lib"))
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  defp write_file(relative_path, content) do
    path = Path.join(@tmp_dir, relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  describe "from_sources/2" do
    test "analyzes multiple files" do
      path_a =
        write_file("lib/mod_a.ex", """
        defmodule ModA do
          def foo(x), do: x + 1
        end
        """)

      path_b =
        write_file("lib/mod_b.ex", """
        defmodule ModB do
          def bar(y), do: y * 2
        end
        """)

      project = Project.from_sources([path_a, path_b])
      assert map_size(project.modules) == 2
      assert map_size(project.nodes) > 0
    end

    test "can discard per-module dependence graphs after merging" do
      path =
        write_file("lib/compact.ex", """
        defmodule CompactProject do
          def run(value), do: value
        end
        """)

      project = Project.from_sources([path], retain_module_sdgs: false)

      assert project.modules == %{}
      assert map_size(project.nodes) > 0
      assert Graph.num_vertices(project.graph) > 0
    end

    test "builds merged call graph" do
      path_a =
        write_file("lib/caller.ex", """
        defmodule Caller do
          def run(x), do: Helper.transform(x)
        end
        """)

      path_b =
        write_file("lib/helper.ex", """
        defmodule Helper do
          def transform(y), do: y + 1
        end
        """)

      project = Project.from_sources([path_a, path_b])
      cg_edges = Graph.edges(project.call_graph)
      assert cg_edges != []
    end
  end

  describe "from_mix_project/1" do
    test "includes package-style top-level app sources" do
      write_file("package_a/lib/package_a.ex", "defmodule PackageA do\n  def a, do: 1\nend\n")

      File.cd!(@tmp_dir, fn ->
        project = Project.from_mix_project()

        modules =
          project.nodes
          |> Map.values()
          |> Enum.filter(&(&1.type == :module_def))
          |> Enum.map(& &1.meta[:name])

        assert PackageA in modules
      end)
    end

    test "includes umbrella app sources" do
      write_file("apps/app_a/lib/umbrella_a.ex", "defmodule UmbrellaA do\n  def a, do: 1\nend\n")

      write_file(
        "apps/app_b/lib/umbrella_b.ex",
        "defmodule UmbrellaB do\n  def b, do: UmbrellaA.a()\nend\n"
      )

      File.cd!(@tmp_dir, fn ->
        project = Project.from_mix_project()

        modules =
          project.nodes
          |> Map.values()
          |> Enum.filter(&(&1.type == :module_def))
          |> Enum.map(& &1.meta[:name])

        assert UmbrellaA in modules
        assert UmbrellaB in modules
      end)
    end
  end

  describe "Reach.CLI.Project" do
    test "loads projects without retaining per-module dependence graphs" do
      path =
        write_file("lib/compact_cli.ex", """
        defmodule CompactCLIProject do
          def run(value), do: value
        end
        """)

      project = CLIProject.load(paths: [path], quiet: true, retain_module_sdgs: false)

      assert project.modules == %{}
      assert map_size(project.nodes) > 0
    end

    test "clears function index cache between loaded projects" do
      path_a = write_file("lib/cache_a.ex", "defmodule CacheA do\n  def only_a, do: 1\nend\n")
      path_b = write_file("lib/cache_b.ex", "defmodule CacheB do\n  def only_b, do: 2\nend\n")

      project_a = CLIProject.load(paths: [path_a], quiet: true)
      assert Query.resolve_target(project_a, "only_a/0") == {CacheA, :only_a, 0}

      project_b = CLIProject.load(paths: [path_b], quiet: true)
      assert Query.resolve_target(project_b, "only_b/0") == {CacheB, :only_b, 0}
      assert Query.resolve_target(project_b, "only_a/0") == nil
      assert Query.resolve_target(project_b, CacheB) == nil
    end
  end

  describe "from_glob/2" do
    test "finds and analyzes files" do
      write_file("lib/glob_a.ex", "defmodule GlobA do\n  def a, do: 1\nend\n")
      write_file("lib/glob_b.ex", "defmodule GlobB do\n  def b, do: 2\nend\n")

      project = Project.from_glob(Path.join(@tmp_dir, "lib/**/*.ex"))
      assert map_size(project.modules) == 2
    end
  end

  describe "summarize_dependency/1" do
    test "computes param flows for a compiled module" do
      summaries = Project.summarize_dependency(Map)

      get_summary = summaries[{Map, :get, 2}]
      assert get_summary != nil
      assert is_map(get_summary)
    end

    test "returns empty map for non-existing module" do
      assert Project.summarize_dependency(NonExistent12345) == %{}
    end
  end

  describe "taint_analysis/2" do
    test "finds taint flows across modules" do
      path_a =
        write_file("lib/input.ex", """
        defmodule Input do
          def get_param(conn), do: conn.params["id"]
        end
        """)

      path_b =
        write_file("lib/handler.ex", """
        defmodule Handler do
          def handle(conn) do
            id = get_param(conn)
            execute(id)
          end

          defp get_param(conn), do: conn
          defp execute(query), do: query
        end
        """)

      project = Project.from_sources([path_a, path_b])

      results =
        Project.taint_analysis(project,
          sources: [type: :call, function: :get_param],
          sinks: [type: :call, function: :execute]
        )

      assert is_list(results)
    end
  end

  describe "cross-module call resolution" do
    test "links parameter edges across modules" do
      path_a =
        write_file("lib/api.ex", """
        defmodule Api do
          def process(data), do: Worker.run(data)
        end
        """)

      path_b =
        write_file("lib/worker.ex", """
        defmodule Worker do
          def run(input), do: input + 1
        end
        """)

      project = Project.from_sources([path_a, path_b])
      edges = Graph.edges(project.graph)
      labels = Enum.map(edges, & &1.label) |> Enum.uniq()

      # Should have cross-module call edges
      assert :call in labels or :parameter_in in labels or :summary in labels
    end
  end
end
