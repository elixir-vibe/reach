defmodule Reach.Plugins.Ecto.Smells.FloatMoneyTest do
  use ExUnit.Case, async: true

  alias Reach.Check.Smells
  alias Reach.Plugins.Ecto
  alias Reach.Plugins.Ecto.Smells.FloatMoney
  alias Reach.Project
  alias Reach.Smell.Finding
  alias Reach.Smell.PatternConfig

  test "plugin-provided ExAST pattern smells run through the smell registry" do
    project =
      project_from_file(~S'''
      defmodule MyApp.Invoice do
        use Ecto.Schema

        schema "invoices" do
          field :amount, :float
        end
      end
      ''')

    assert [%Finding{kind: :ecto_float_money}] = Smells.run(project)
  end

  test "inferred prefilter uses selector steps and ignores predicate internals" do
    %{queries: queries} = FloatMoney.__reach_pattern_check__()

    field_query =
      Enum.find(queries, fn {_fun_name, _kind, message, _prefilter, _remediation_safety} ->
        message =~ "schema field"
      end)

    {_fun_name, _kind, _message, prefilter, _remediation_safety} =
      PatternConfig.normalize_query(FloatMoney, field_query)

    refute PatternConfig.source_matches?("defmodule M do\n  false\nend", prefilter)

    assert PatternConfig.source_matches?(
             "defmodule M do\n  field :amount, :float\nend",
             prefilter
           )
  end

  test "ignores non-money field names" do
    project =
      project_from_file(~S'''
      defmodule MyApp.Weather do
        use Ecto.Schema

        schema "readings" do
          field :temperature, :float
        end
      end
      ''')

    assert [] = Smells.run(project)
  end

  defp project_from_file(source) do
    dir = Path.join(System.tmp_dir!(), "reach-ecto-smell-#{System.unique_integer()}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "sample.ex")
    File.write!(path, source)
    on_exit(fn -> File.rm_rf(dir) end)

    Project.from_sources([path], plugins: [Ecto])
  end
end
