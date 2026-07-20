defmodule Reach.Smell.PatternRunnerTest do
  use ExUnit.Case, async: true

  alias Reach.Project

  alias Reach.Smell.{
    Checks.CollectionIdioms,
    Checks.PipelineWaste,
    PatternConfig,
    PatternRunner,
    SourceRunner
  }

  test "normalizes source patterns into reusable compiled patterns" do
    config = PatternConfig.normalize(CollectionIdioms, CollectionIdioms.__reach_pattern_check__())

    assert Enum.all?(config.patterns, fn
             {%ExAST.CompiledPattern{}, _kind, _message, _prefilter, _safety} -> true
             _pattern -> false
           end)
  end

  test "scans files concurrently while preserving input order" do
    dir =
      Path.join(System.tmp_dir!(), "reach-pattern-order-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)

    paths =
      for name <- ["first", "second"] do
        path = Path.join(dir, "#{name}.ex")

        File.write!(path, """
        defmodule #{Macro.camelize(name)} do
          def count(items), do: items |> Enum.filter(&is_atom/1) |> length()
        end
        """)

        path
      end

    on_exit(fn -> File.rm_rf(dir) end)

    findings = PatternRunner.run(%{}, [PipelineWaste], paths, max_concurrency: 2)

    assert Enum.map(findings, & &1.location) == Enum.map(paths, &"#{&1}:2")
  end

  test "isolates source files with dynamically unquoted import options" do
    source = """
    defmodule DynamicImport do
      defmacro __using__(opts) do
        quote do
          import DynamicImport, unquote(Keyword.drop(opts, [:fill]))
        end
      end
    end
    """

    path =
      Path.join(
        System.tmp_dir!(),
        "reach-dynamic-import-#{System.unique_integer([:positive])}.ex"
      )

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)

    project = Project.from_sources([path])
    assert SourceRunner.run(project, [CollectionIdioms]) == []
  end

  test "isolates source files whose import metadata is not enumerable" do
    source = """
    defmodule UnusualImport do
      import Tentacat, only: [except: 2, delete: 2]
      def count(values), do: values |> Enum.filter(&is_atom/1) |> length()
    end
    """

    path =
      Path.join(
        System.tmp_dir!(),
        "reach-unusual-import-#{System.unique_integer([:positive])}.ex"
      )

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)

    project = Project.from_sources([path])
    assert SourceRunner.run(project, [CollectionIdioms]) == []
  end
end
