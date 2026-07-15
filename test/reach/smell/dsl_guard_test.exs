defmodule Reach.Smell.DSLGuardTest do
  use ExUnit.Case, async: true

  alias Reach.Check.Smells
  alias Reach.Project
  alias Reach.Smell.{Finding, Source, Suppressions}

  defmodule SyntheticCheck do
    @behaviour Reach.Smell.Check

    @impl true
    def kinds, do: [:synthetic_generic]

    @impl true
    def run(project) do
      [file] = Source.module_files(project)

      for line <- [3, 6] do
        Finding.new(
          kind: :synthetic_generic,
          message: "synthetic generic finding",
          location: %{file: file, line: line}
        )
      end
    end
  end

  defmodule CustomDSL do
  end

  test "plugin guards suppress generic findings inside reinterpreted AST ranges" do
    project =
      project_from_source(
        """
        defmodule QueryExample do
          def run(items) do
            outside = transform(items)
            query =
              from p in Post,
                where: p.id in transform(items)
            {outside, query}
          end
        end
        """,
        [Reach.Plugins.Ecto]
      )

    findings =
      Smells.run(project,
        smells: [custom_checks: [SyntheticCheck]],
        clone_analysis: [provider: false]
      )

    assert [%Finding{kind: :synthetic_generic} = finding] =
             Enum.filter(findings, &(&1.kind == :synthetic_generic))

    assert {_file, 3} = Suppressions.location(finding)
  end

  test "configured DSL macros guard unknown libraries" do
    project =
      project_from_source("""
      defmodule CustomExample do
        def run(value) do
          outside = transform(value)
          result =
            #{inspect(CustomDSL)}.expr do
              transform(value)
            end
          {outside, result}
        end
      end
      """)

    findings =
      Smells.run(project,
        smells: [
          custom_checks: [SyntheticCheck],
          dsl_macros: [{CustomDSL, :expr, 1}]
        ],
        clone_analysis: [provider: false]
      )

    assert [%Finding{kind: :synthetic_generic} = finding] =
             Enum.filter(findings, &(&1.kind == :synthetic_generic))

    assert {_file, 3} = Suppressions.location(finding)
  end

  test "plugin-specific findings remain active inside guarded DSL ranges" do
    project =
      project_from_source(
        """
        defmodule QueryExample do
          def run do
            from p in Post, c in Comment, select: {p.id, c.id}
          end
        end
        """,
        [Reach.Plugins.Ecto]
      )

    assert Enum.any?(Smells.run(project), &(&1.kind == :ecto_implicit_cross_join))
  end

  test "Ash expression and resource blocks declare reinterpreted semantics" do
    assert reinterpreted?("Ash.Expr.expr(foo > 0)", Reach.Plugins.Ash)
    assert reinterpreted?("policies do\n  policy action(:read)\nend", Reach.Plugins.Ash)
    refute reinterpreted?("Ash.read!(query)", Reach.Plugins.Ash)
  end

  test "Nx defn declarations declare reinterpreted semantics" do
    assert reinterpreted?("defn add_one(x), do: x + 1", Reach.Plugins.Nx)
    refute reinterpreted?("def add_one(x), do: x + 1", Reach.Plugins.Nx)
  end

  defp reinterpreted?(source, plugin) do
    ast = Sourceror.parse_string!(source)

    {_ast, found?} =
      Macro.prewalk(ast, false, fn node, found? ->
        {node, found? or plugin.reinterpreted_ast?(node)}
      end)

    found?
  end

  defp project_from_source(source, plugins \\ []) do
    path = Path.join(System.tmp_dir!(), "reach-dsl-guard-#{System.unique_integer()}.ex")
    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)
    Project.from_sources([path], plugins: plugins)
  end
end
