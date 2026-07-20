defmodule Reach.Smell.SuppressionsTest do
  use ExUnit.Case, async: true

  alias Reach.Check.Smells
  alias Reach.Config
  alias Reach.Project
  alias Reach.Smell.{Finding, Suppressions}

  test "global path ignore suppresses all smell kinds in matching files" do
    path =
      fixture("global_path", """
      defmodule Generated.GlobalPath do
        def run(items), do: items |> Enum.filter(& &1.active?) |> length()
      end
      """)

    project = Project.from_sources([path])

    assert Smells.run(project, []) != []

    assert Smells.run(project,
             smells: [ignore: [paths: [Path.join(Path.dirname(path), "**")]]]
           ) == []
  end

  test "per-check path ignore suppresses only that smell kind" do
    path =
      fixture("per_check_path", """
      defmodule Generated.PerCheckPath do
        def first(items), do: items |> Enum.filter(& &1.active?) |> length()
        def a, do: %{id: 1, name: "a", role: :user}
        def b, do: %{id: 2, name: "b", role: :user}
        def c, do: %{id: 3, name: "c", role: :user}
      end
      """)

    project = Project.from_sources([path])
    initial_findings = Smells.run(project, [])

    assert Enum.any?(initial_findings, &(&1.kind == :fixed_shape_map))
    assert Enum.any?(initial_findings, &(&1.kind == :suboptimal))

    findings =
      Smells.run(project,
        smells: [fixed_shape_map: [ignore: [paths: [Path.join(Path.dirname(path), "**")]]]]
      )

    refute Enum.any?(findings, &(&1.kind == :fixed_shape_map))
    assert Enum.any?(findings, &(&1.kind == :suboptimal))
  end

  test "module ignore suppresses matching module findings" do
    path =
      fixture("module_ignore", """
      defmodule Generated.ModuleIgnore do
        def run(items), do: items |> Enum.filter(& &1.active?) |> length()
      end
      """)

    project = Project.from_sources([path])

    assert Smells.run(project, smells: [ignore: [modules: ["Generated.ModuleIgnore"]]]) == []
  end

  test "module ignore resolves findings to the innermost containing module" do
    path =
      fixture("nested_module_ignore", """
      defmodule Generated.Outer do
        def outer(items), do: items |> Enum.filter(& &1.active?) |> length()

        defmodule Inner do
          def inner(items), do: items |> Enum.filter(& &1.active?) |> length()
        end
      end
      """)

    project = Project.from_sources([path])

    findings =
      project
      |> Smells.run(smells: [ignore: [modules: ["Generated.Outer.Inner"]]])
      |> Enum.filter(&(&1.kind == :suboptimal))

    assert [finding] = findings
    assert {_file, 2} = Suppressions.location(finding)
  end

  test "module suppression skips project indexing when no module ignores are configured" do
    finding = Finding.new(kind: :suboptimal, message: "example", location: "sample.ex:1")
    project_without_nodes = %{nodes: :not_enumerable}

    refute Suppressions.suppressed_by_module?(
             finding,
             project_without_nodes,
             Config.normalize([])
           )
  end

  test "disable-next-line source comment suppresses one finding" do
    path =
      fixture("next_line", """
      defmodule Generated.NextLine do
        # reach:disable-next-line suboptimal
        def run(items), do: items |> Enum.filter(& &1.active?) |> length()
      end
      """)

    project = Project.from_sources([path])

    refute Enum.any?(Smells.run(project, []), &(&1.kind == :suboptimal))
  end

  test "concise disable source comment suppresses the next line" do
    path =
      fixture("concise", """
      defmodule Generated.Concise do
        # reach:disable suboptimal -- generated compatibility layer
        def run(items), do: items |> Enum.filter(& &1.active?) |> length()
      end
      """)

    project = Project.from_sources([path])

    refute Enum.any?(Smells.run(project, []), &(&1.kind == :suboptimal))
  end

  test "disable-for-this-file suppresses all findings in the file" do
    path =
      fixture("this_file", """
      # reach:disable-for-this-file smells
      defmodule Generated.ThisFile do
        def run(items), do: items |> Enum.filter(& &1.active?) |> length()
      end
      """)

    project = Project.from_sources([path])

    assert Smells.run(project, []) == []
  end

  test "unknown source suppression tokens do not create atoms or crash" do
    token = "synthetic_unknown_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> :erlang.binary_to_existing_atom(token, :utf8) end

    path =
      fixture("unknown_token", """
      defmodule Generated.UnknownToken do
        # reach:disable-next-line #{token}
        def run(items), do: items |> Enum.filter(& &1.active?) |> length()
      end
      """)

    project = Project.from_sources([path])

    assert Enum.any?(Smells.run(project, []), &(&1.kind == :suboptimal))
    assert_raise ArgumentError, fn -> :erlang.binary_to_existing_atom(token, :utf8) end
  end

  defp fixture(name, source) do
    dir = Path.join(System.tmp_dir!(), "reach-suppressions-#{name}-#{System.unique_integer()}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "sample.ex")
    File.write!(path, source)
    on_exit(fn -> File.rm_rf(dir) end)
    path
  end
end
