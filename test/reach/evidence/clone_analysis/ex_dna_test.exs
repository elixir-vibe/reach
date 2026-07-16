defmodule Reach.Evidence.CloneAnalysis.ExDNATest do
  use ExUnit.Case, async: true

  alias Reach.Config
  alias Reach.Evidence.Bypass
  alias Reach.Evidence.CloneAnalysis.ExDNA
  alias Reach.IR.Node
  alias Reach.Project

  test "ignores non-Elixir source files in the project graph" do
    dir = Path.join(System.tmp_dir!(), "reach-ex-dna-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    elixir_path = Path.join(dir, "sample.ex")
    javascript_path = Path.join(dir, "app.js")

    File.write!(elixir_path, "defmodule Sample do\n  def ok, do: :ok\nend\n")
    File.write!(javascript_path, "const theme = prefersLight ? 'light' : 'dark';\n")

    project =
      [elixir_path]
      |> Project.from_sources()
      |> add_javascript_module_node(javascript_path)

    assert [] = ExDNA.analyze(project, %Reach.Config.CloneAnalysis{min_mass: 3})
  end

  test "keeps only clone families spanning project and direct-dependency source" do
    root =
      Path.join(System.tmp_dir!(), "reach-dependency-clone-#{System.unique_integer([:positive])}")

    project_file = Path.join(root, "project/lib/normalizer.ex")
    dependency_root = Path.join(root, "deps/sample_dep")
    dependency_file = Path.join(dependency_root, "lib/sample_dep/normalizer.ex")

    File.mkdir_p!(Path.dirname(project_file))
    File.mkdir_p!(Path.dirname(dependency_file))
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(project_file, duplicate_source("ProjectNormalizer"))
    File.write!(dependency_file, duplicate_source("SampleDep.Normalizer"))

    project = Project.from_sources([project_file])

    config = %Config.CloneAnalysis{
      include_deps: true,
      dep_paths_limit: 2,
      min_mass: 3,
      min_occurrences: 2,
      max_clones: 10
    }

    assert [clone | _] =
             ExDNA.dependency_clones(project, config, %{sample_dep: dependency_root})

    assert Enum.any?(clone.fragments, &(&1.origin == :project))
    assert Enum.any?(clone.fragments, &(&1.origin == :dependency))
    assert Enum.all?(clone.fragments, &(&1.origin in [:project, :dependency]))

    assert [fact | _] = Bypass.from_dependency_clones([clone])
    assert fact.family == :dependency_bypass
    assert fact.kind == :structural_reimplementation
    assert fact.confidence == :high
    assert fact.data.provider == :sample_dep
    assert fact.data.origin == :dependency_clone
    assert Bypass.fact?(fact)
  end

  defp duplicate_source(module) do
    """
    defmodule #{module} do
      def normalize(items) do
        items
        |> Enum.map(fn item -> String.trim(item) end)
        |> Enum.reject(fn item -> item == "" end)
        |> Enum.map(fn item -> String.downcase(item) end)
        |> Enum.uniq()
      end
    end
    """
  end

  defp add_javascript_module_node(project, file) do
    node = %Node{
      id: 999_999,
      type: :module_def,
      meta: %{name: :JavascriptApp},
      source_span: %{file: file, start_line: 1, start_col: 1, end_line: 1, end_col: 50}
    }

    %{project | nodes: Map.put(project.nodes, node.id, node)}
  end
end
