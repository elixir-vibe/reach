defmodule Reach.Smell.PatternRunnerTest do
  use ExUnit.Case, async: true

  alias Reach.Project
  alias Reach.Smell.{Checks.CollectionIdioms, SourceRunner}

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
