defmodule Reach.Check.Changed.AccessStrictnessTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Reach.Check.Changed
  alias Reach.Check.Changed.AccessStrictness
  alias Reach.Check.Changed.Range
  alias Reach.CLI.Render.Check, as: CheckRender

  test "detects a required map pattern replaced by Map.get and names malformed callers" do
    old_source = """
    defmodule StrictState do
      def search(%{search: search}), do: search
    end
    """

    new_source = """
    defmodule StrictState do
      def search(state), do: Map.get(state, :search)
    end

    defmodule Caller do
      def run, do: StrictState.search(%{})
    end
    """

    {project, path} = project_from_source(new_source)

    assert [downgrade] = analyze(project, path, old_source, new_source)
    assert downgrade.kind == :pattern_to_get
    assert downgrade.module == "StrictState"
    assert downgrade.function == :search
    assert downgrade.parameter_index == 0
    assert downgrade.key == :search
    assert downgrade.old_line == 2
    assert downgrade.new_line == 2

    assert [%{id: "Caller.run/0", argument: "map literal without :search"}] =
             downgrade.malformed_callers

    assert downgrade.suggestion =~ "Caller.run/0"
  end

  test "detects an internal required map match replaced by Map.get" do
    old_source = """
    defmodule StrictState do
      def search(state) do
        %{search: search} = state
        search
      end
    end
    """

    new_source = """
    defmodule StrictState do
      def search(state) do
        Map.get(state, :search)
      end
    end
    """

    {project, path} = project_from_source(new_source)

    ranges = [Range.new(old_start: 3, old_count: 2, new_start: 3, new_count: 1)]

    assert [%{kind: :pattern_to_get}] =
             AccessStrictness.analyze(project, "HEAD", %{path => ranges},
               old_sources: %{path => old_source},
               new_sources: %{path => new_source}
             )
  end

  test "detects field and fetch downgrades" do
    cases = [
      {:field_to_get, "state.search"},
      {:fetch_to_get, "Map.fetch!(state, :search)"}
    ]

    Enum.each(cases, fn {kind, strict_expression} ->
      old_source = function_source(strict_expression)
      new_source = function_source("Map.get(state, :search)")
      {project, path} = project_from_source(new_source)

      assert [%{kind: ^kind, key: :search}] = analyze(project, path, old_source, new_source)
    end)
  end

  test "does not report additions when strict access remains" do
    old_source =
      function_source("state.search")

    new_source =
      function_source("{state.search, Map.get(state, :search)}")

    {project, path} = project_from_source(new_source)
    assert [] = analyze(project, path, old_source, new_source)
  end

  test "does not pair accesses to different keys" do
    old_source = function_source("state.search")
    new_source = function_source("Map.get(state, :sort)")
    {project, path} = project_from_source(new_source)

    assert [] = analyze(project, path, old_source, new_source)
  end

  test "changed analysis raises overall risk without changing per-function risk" do
    old_source = function_source("state.search")
    new_source = function_source("Map.get(state, :search)")
    {project, path} = project_from_source(new_source)
    ranges = %{path => [changed_range()]}

    result =
      Changed.run(project, [clone_analysis: [provider: false]],
        base: "HEAD",
        files: [path],
        changed_ranges: ranges,
        old_sources: %{path => old_source},
        new_sources: %{path => new_source}
      )

    assert result.risk == :medium
    assert result.risk_reasons == ["access strictness downgraded (1)"]
    assert [%{risk: :low}] = result.changed_functions
    assert [%{kind: :field_to_get}] = result.strictness_downgrades

    output = capture_io(fn -> CheckRender.render_changed_text(result) end)
    assert output =~ "Access strictness downgrades (1)"
    assert output =~ "field to get StrictState.search/1 key=:search"
  end

  defp analyze(project, path, old_source, new_source) do
    AccessStrictness.analyze(project, "HEAD", %{path => [changed_range()]},
      old_sources: %{path => old_source},
      new_sources: %{path => new_source}
    )
  end

  defp changed_range do
    Range.new(old_start: 2, old_count: 1, new_start: 2, new_count: 1)
  end

  defp function_source(expression) do
    """
    defmodule StrictState do
      def search(state), do: #{expression}
    end
    """
  end

  defp project_from_source(source) do
    path =
      Path.join(
        System.tmp_dir!(),
        "reach-access-strictness-#{System.unique_integer([:positive])}.ex"
      )

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)
    {Reach.Project.from_sources([path]), path}
  end
end
