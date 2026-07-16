defmodule Reach.Smell.Checks.TotalFunctionLaunderingTest do
  use ExUnit.Case, async: true

  alias Reach.Check.Smells
  alias Reach.Smell.Finding

  test "flags a catch-all that launders invalid input into the declared domain" do
    project =
      project_from_string("""
      defmodule Catalog.Model do
        @type routing_strategy :: :ordered | :shuffle | :round_robin | :lowest_cost

        defp routing_strategy(strategy) when strategy in [:shuffle, :round_robin, :lowest_cost],
          do: strategy

        defp routing_strategy("shuffle"), do: :shuffle
        defp routing_strategy("round_robin"), do: :round_robin
        defp routing_strategy("lowest_cost"), do: :lowest_cost
        defp routing_strategy(_strategy), do: :ordered
      end
      """)

    assert [%Finding{} = finding] = laundering_findings(project)
    assert finding.kind == :total_function_laundering
    assert finding.location.line == 10
    assert finding.confidence == :high
    assert finding.message =~ "silently coerces"
    assert finding.message =~ ":ordered"
    assert finding.occurrences == 5
  end

  test "flags a fallback returned by another literal domain clause" do
    project =
      project_from_string("""
      defmodule Parser do
        defp mode(:fast), do: :fast
        defp mode(:safe), do: :safe
        defp mode(_invalid), do: :safe
      end
      """)

    assert [%{kind: :total_function_laundering}] = laundering_findings(project)
  end

  test "does not flag a best-effort serializer that transforms its catch-all input" do
    project =
      project_from_string("""
      defmodule ExternalValue do
        defp external_value(:missing), do: "missing"
        defp external_value(:empty), do: "empty"
        defp external_value(value), do: inspect(value)
      end
      """)

    assert [] = laundering_findings(project)
  end

  test "does not flag presentation mappings with intentional display defaults" do
    project =
      project_from_string("""
      defmodule DiffFormat do
        defp diff_mark(:add), do: "+"
        defp diff_mark(:remove), do: "-"
        defp diff_mark(:replace), do: "~"
        defp diff_mark(_operation), do: "~"
      end
      """)

    assert [] = laundering_findings(project)
  end

  test "requires every constrained clause to preserve the logical domain value" do
    project =
      project_from_string("""
      defmodule Flash do
        defp flash_level(level) when level in [:info, :error], do: level
        defp flash_level(:warning), do: :error
        defp flash_level(_level), do: :info
      end
      """)

    assert [] = laundering_findings(project)
  end

  test "does not infer a success domain from an unrelated fallback constant" do
    project =
      project_from_string("""
      defmodule Parser do
        defp mode("fast"), do: :fast
        defp mode("safe"), do: :safe
        defp mode(_invalid), do: :unknown
      end
      """)

    assert [] = laundering_findings(project)
  end

  test "does not flag public normalization APIs" do
    project =
      project_from_string("""
      defmodule Parser do
        def mode(:fast), do: :fast
        def mode(:safe), do: :safe
        def mode(_invalid), do: :safe
      end
      """)

    assert [] = laundering_findings(project)
  end

  test "requires more than one constrained domain clause" do
    project =
      project_from_string("""
      defmodule Parser do
        defp enabled(:enabled), do: :enabled
        defp enabled(_invalid), do: :enabled
      end
      """)

    assert [] = laundering_findings(project)
  end

  test "allows catch-alls that reject unsupported input" do
    project =
      project_from_string("""
      defmodule Parser do
        defp mode(:fast), do: :fast
        defp mode(:safe), do: :safe
        defp mode(value), do: raise(ArgumentError, "invalid mode: \#{inspect(value)}")
      end
      """)

    assert [] = laundering_findings(project)
  end

  test "keeps same-named functions in separate modules independent" do
    project =
      project_from_string("""
      defmodule FastParser do
        defp mode(:fast), do: :fast
        defp mode(_invalid), do: :fast
      end

      defmodule SafeParser do
        defp mode(:safe), do: :safe
        defp mode(_invalid), do: :safe
      end
      """)

    assert [] = laundering_findings(project)
  end

  defp laundering_findings(project) do
    project
    |> Smells.run()
    |> Enum.filter(&(&1.kind == :total_function_laundering))
  end

  defp project_from_string(source) do
    path =
      Path.join(
        System.tmp_dir!(),
        "reach-total-function-laundering-#{System.unique_integer([:positive])}.ex"
      )

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)
    Reach.Project.from_sources([path])
  end
end
