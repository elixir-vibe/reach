defmodule Reach.Check.Changed.SuppressionRatchetTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Reach.Check.Changed
  alias Reach.Check.Changed.Range
  alias Reach.Check.Changed.SuppressionRatchet
  alias Reach.CLI.Render.Check, as: CheckRender

  test "classifies reasoned and reasonless additions" do
    old_source = module_source("")

    new_source =
      module_source("""
      # reach:disable-next-line default_drift
      # reach:disable-next-line dual_key_access -- external payload remains string-keyed
      """)

    {project, path} = project_from_source(new_source)
    report = analyze(path, old_source, new_source)

    assert report.total_before == 0
    assert report.total_after == 2
    assert report.unchanged_count == 0
    assert length(report.added) == 2
    assert [%{tokens: ["default_drift"], reason: nil}] = report.reasonless_added

    result =
      Changed.run(project, [clone_analysis: [provider: false]],
        base: "HEAD",
        files: [path],
        changed_ranges: %{path => [full_range(old_source, new_source)]},
        old_sources: %{path => old_source},
        new_sources: %{path => new_source}
      )

    assert result.risk == :medium
    assert "reasonless suppressions added (1)" in result.risk_reasons
    assert result.suppression_report.reasonless_added == report.reasonless_added

    output = capture_io(fn -> CheckRender.render_changed_text(result) end)
    assert output =~ "Suppression changes (2 added, 0 removed, 0 unchanged)"
    assert output =~ "default_drift -- missing reason"
  end

  test "reasoned additions remain visible without raising risk" do
    old_source = module_source("")
    new_source = module_source("# reach:disable-for-this-file default_drift -- legacy API\n")
    {project, path} = project_from_source(new_source)

    result =
      Changed.run(project, [clone_analysis: [provider: false]],
        base: "HEAD",
        files: [path],
        changed_ranges: %{path => [full_range(old_source, new_source)]},
        old_sources: %{path => old_source},
        new_sources: %{path => new_source}
      )

    assert result.risk == :low
    assert [%{reason: "legacy API"}] = result.suppression_report.added
    assert result.suppression_report.reasonless_added == []
  end

  test "reports removed suppressions" do
    old_source = module_source("# reach:disable-for-this-file default_drift -- legacy API\n")
    new_source = module_source("")
    {_project, path} = project_from_source(new_source)
    report = analyze(path, old_source, new_source)

    assert report.added == []
    assert [%{tokens: ["default_drift"]}] = report.removed
    assert report.total_before == 1
    assert report.total_after == 0
  end

  test "a moved unchanged directive is not a new suppression" do
    old_source = """
    # reach:disable-for-this-file default_drift -- legacy API
    defmodule Suppressed do
      def run(value), do: value
    end
    """

    new_source = """
    defmodule Suppressed do
      # reach:disable-for-this-file default_drift -- legacy API
      def run(value), do: value
    end
    """

    {_project, path} = project_from_source(new_source)
    report = analyze(path, old_source, new_source)

    assert report.added == []
    assert report.removed == []
    assert report.unchanged_count == 1
  end

  defp analyze(path, old_source, new_source) do
    SuppressionRatchet.analyze("HEAD", %{path => [full_range(old_source, new_source)]},
      old_sources: %{path => old_source},
      new_sources: %{path => new_source}
    )
  end

  defp module_source(comments) do
    """
    defmodule Suppressed do
    #{comments}  def run(value), do: value
    end
    """
  end

  defp full_range(old_source, new_source) do
    Range.new(
      old_start: 1,
      old_count: line_count(old_source),
      new_start: 1,
      new_count: line_count(new_source)
    )
  end

  defp line_count(source), do: source |> String.split("\n", trim: false) |> length()

  defp project_from_source(source) do
    path =
      Path.join(
        System.tmp_dir!(),
        "reach-suppression-ratchet-#{System.unique_integer([:positive])}.ex"
      )

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)
    {Reach.Project.from_sources([path]), path}
  end
end
