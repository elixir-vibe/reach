defmodule Reach.Map.AnalysisTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Reach.CLI.Render.Map, as: MapRender
  alias Reach.Map.Analysis

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
end
