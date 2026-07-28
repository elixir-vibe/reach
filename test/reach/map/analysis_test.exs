defmodule Reach.Map.AnalysisTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Reach.CLI.Render.Map, as: MapRender
  alias Reach.Map.Analysis

  test "effect summaries expose classification sources and local unknown targets" do
    project =
      project("""
      defmodule EffectSummaryExample do
        def helper(value), do: value + 1
        def known(value), do: helper(value)
        def unknown(value), do: missing(value)
      end
      """)

    summary = Analysis.section_data(project, :effects, %{top: 20}, nil)

    assert Enum.any?(summary.sources, &(&1.source == :local_inference))

    assert Enum.any?(summary.unknown_calls, fn call ->
             call.module == "EffectSummaryExample" and call.function == "missing" and
               call.kind == :local
           end)

    refute Enum.any?(summary.unknown_calls, &(&1.module == "Kernel"))
  end

  test "effect summaries exclude compile-time type and DSL calls" do
    project =
      project("""
      defmodule RuntimeEffectSummary do
        @type t :: External.Type.t()
        configure :compile_time

        def run, do: :ok
      end
      """)

    summary = Analysis.section_data(project, :effects, %{top: 20}, nil)

    assert summary.total_calls == 0
    assert summary.unknown_calls == []
  end

  test "project summary exposes total and reasonless source suppressions" do
    source = """
    # reach:disable-for-this-file default_drift -- legacy input contract
    defmodule SuppressedSummary do
      # reach:disable-next-line pipeline_waste
      def run(value), do: value
    end
    """

    path =
      Path.join(
        System.tmp_dir!(),
        "reach-map-suppressions-#{System.unique_integer([:positive])}.ex"
      )

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)
    project = Reach.Project.from_sources([path])

    summary = Analysis.summary(project, nil)
    assert summary.suppressions == %{total: 2, reasonless: 1}
    assert Analysis.summary(project, "unmatched/path").suppressions == %{total: 0, reasonless: 0}

    output = capture_io(fn -> MapRender.render(%{summary: summary, sections: %{}}, "text") end)
    assert output =~ "suppressions=2 reasonless=1"
  end

  defp project(source) do
    path =
      Path.join(
        System.tmp_dir!(),
        "reach-map-analysis-#{System.unique_integer([:positive])}.ex"
      )

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)
    Reach.Project.from_sources([path], plugins: [])
  end
end
