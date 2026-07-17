defmodule Reach.Check.Changed.ShapeEntropyTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Reach.Check.Changed
  alias Reach.Check.Changed.Range
  alias Reach.CLI.Render.Check, as: CheckRender
  alias Reach.Project

  test "reports changed callers that increase parameter shape entropy" do
    old_source = """
    defmodule EntropyRegressionSample do
      def first, do: process(%{id: 1, name: "A", email: "a@example.com"})
      def second do
        entity = %{id: 2, status: :active, role: :admin}
        archive(entity)
      end

      def process(entity) do
        Map.get(entity, :id)
        Map.get(entity, :name)
        Map.get(entity, :status)
      end

      def archive(entity), do: entity
    end
    """

    new_source = String.replace(old_source, "archive(entity)", "process(entity)")

    path = temp_source(new_source)
    project = Project.from_sources([path])
    ranges = %{path => [Range.new(old_start: 5, old_count: 1, new_start: 5, new_count: 1)]}

    result =
      Changed.run(project, [],
        base: "base",
        files: [path],
        changed_ranges: ranges,
        old_revision: "old",
        old_sources: %{path => old_source},
        new_sources: %{path => new_source}
      )

    assert [regression] = result.shape_entropy_regressions
    assert regression.target == "EntropyRegressionSample.process/1"
    assert regression.parameter == "entity"
    assert regression.old_entropy == 0.0
    assert regression.new_entropy == 0.8
    assert regression.delta == 0.8
    assert result.risk == :medium
    assert "parameter shape entropy increased (1)" in result.risk_reasons

    output = capture_io(fn -> CheckRender.render_changed_text(result) end)
    assert output =~ "Parameter shape entropy regressions"
    assert output =~ "entropy=0.00 -> 0.80 delta=+0.80"
  end

  test "does not report entropy outside changed ranges" do
    source = """
    defmodule StableEntropySample do
      def first, do: process(%{id: 1, name: "A", email: "a@example.com"})
      def second, do: process(%{id: 2, status: :active, role: :admin})

      def process(entity) do
        Map.get(entity, :id)
        Map.get(entity, :name)
        Map.get(entity, :status)
      end
    end
    """

    path = temp_source(source)
    project = Project.from_sources([path])

    result =
      Changed.run(project, [],
        base: "base",
        files: [path],
        changed_ranges: %{
          path => [Range.new(old_start: 1, old_count: 1, new_start: 1, new_count: 1)]
        },
        old_revision: "old",
        old_sources: %{path => source},
        new_sources: %{path => source}
      )

    assert result.shape_entropy_regressions == []
  end

  defp temp_source(source) do
    path =
      Path.join(System.tmp_dir!(), "reach-entropy-diff-#{System.unique_integer([:positive])}.ex")

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
