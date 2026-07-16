defmodule Reach.Check.Changed.DisplacementTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Reach.Check.Changed
  alias Reach.Check.Changed.Displacement
  alias Reach.Check.Changed.Range
  alias Reach.CLI.Render.Check, as: CheckRender

  test "reports dual-key evidence moved into a helper" do
    old_source = """
    defmodule LooseContract do
      def value(map), do: Map.get(map, :name) || Map.get(map, "name")
    end
    """

    new_source = """
    defmodule LooseContract do
      def value(map), do: loose_value(map)
      defp loose_value(map), do: Map.get(map, :name) || Map.get(map, "name")
    end
    """

    {project, path} = project_from_source(new_source)

    assert [fact] = analyze(project, path, old_source, new_source)
    assert fact.family == :dual_key_contract
    assert fact.status == :displaced
    assert fact.key == "name"
    assert fact.occurrences_before == 2
    assert fact.occurrences_after == 2
    assert [%{function: "LooseContract.value/1"}] = fact.old_locations
    assert [%{function: "LooseContract.loose_value/1"}] = fact.new_locations
  end

  test "changed analysis classifies persistent moved evidence as displacement risk" do
    old_source = """
    defmodule LooseContract do
      def value(map), do: Map.get(map, :name) || Map.get(map, "name")
    end
    """

    new_source = """
    defmodule LooseContract do
      def value(map), do: loose_value(map)
      defp loose_value(map), do: Map.get(map, :name) || Map.get(map, "name")
    end
    """

    {project, path} = project_from_source(new_source)
    range = full_range(old_source, new_source)

    result =
      Changed.run(project, [clone_analysis: [provider: false]],
        base: "HEAD",
        files: [path],
        changed_ranges: %{path => [range]},
        old_sources: %{path => old_source},
        new_sources: %{path => new_source}
      )

    assert result.risk == :medium
    assert "evidence displaced rather than resolved (1)" in result.risk_reasons
    assert [%{family: :dual_key_contract, status: :displaced}] = result.displaced_facts

    output = capture_io(fn -> CheckRender.render_changed_text(result) end)
    assert output =~ "Displaced evidence (1)"
    assert output =~ "dual key contract status=displaced occurrences=2->2"
  end

  test "skips added files without disabling comparable snapshots" do
    old_source = """
    defmodule LooseContract do
      def value(map), do: Map.get(map, :name) || Map.get(map, "name")
    end
    """

    new_source = """
    defmodule LooseContract do
      def value(map), do: loose_value(map)
      defp loose_value(map), do: Map.get(map, :name) || Map.get(map, "name")
    end
    """

    {project, path} = project_from_source(new_source)
    added_path = path <> "s"

    ranges = %{
      path => [full_range(old_source, new_source)],
      added_path => [full_range("", "# added")]
    }

    assert [%{family: :dual_key_contract}] =
             Displacement.analyze(
               project,
               "HEAD",
               ranges,
               [clone_analysis: [provider: false]],
               old_sources: %{path => old_source},
               new_sources: %{path => new_source, added_path => "# added"}
             )
  end

  test "reports conflicting defaults relocated without reducing observations" do
    old_source = """
    defmodule Defaults do
      def values(options), do: {Map.get(options, :timeout, 1_000), Map.get(options, :timeout, 5_000)}
    end
    """

    new_source = """
    defmodule Defaults do
      def values(options), do: timeout_values(options)
      defp timeout_values(options), do: {Map.get(options, :timeout, 1_000), Map.get(options, :timeout, 5_000)}
    end
    """

    {project, path} = project_from_source(new_source)

    assert [%{family: :default_drift, key: "timeout"}] =
             analyze(project, path, old_source, new_source)
  end

  test "does not report a fact that was resolved" do
    old_source = """
    defmodule LooseContract do
      def value(map), do: Map.get(map, :name) || Map.get(map, "name")
    end
    """

    new_source = """
    defmodule LooseContract do
      def value(map), do: Map.fetch!(map, :name)
    end
    """

    {project, path} = project_from_source(new_source)
    assert [] = analyze(project, path, old_source, new_source)
  end

  test "does not report unchanged evidence outside changed lines" do
    old_source = """
    defmodule LooseContract do
      def value(map), do: Map.get(map, :name) || Map.get(map, "name")
    end
    """

    new_source = """
    # New documentation
    defmodule LooseContract do
      def value(map), do: Map.get(map, :name) || Map.get(map, "name")
    end
    """

    {project, path} = project_from_source(new_source)
    insertion = Range.new(old_start: 1, old_count: 0, new_start: 1, new_count: 1)

    assert [] =
             Displacement.analyze(
               project,
               "HEAD",
               %{path => [insertion]},
               [clone_analysis: [provider: false]],
               old_sources: %{path => old_source},
               new_sources: %{path => new_source}
             )
  end

  test "reports an exact whole-function clone moved without reducing clone count" do
    old_source = clone_source("SecondClone")
    new_source = clone_source("ReplacementClone")
    {project, path} = project_from_source(new_source)

    config = [
      clone_analysis: [
        min_mass: 3,
        min_occurrences: 2,
        max_clones: 20,
        literal_mode: :keep
      ]
    ]

    facts = analyze(project, path, old_source, new_source, config)

    assert Enum.any?(facts, fn fact ->
             fact.family == :exact_clone and fact.occurrences_before == 2 and
               fact.occurrences_after == 2
           end)
  end

  defp clone_source(second_module) do
    """
    defmodule FirstClone do
      def normalize(items) do
        items
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
      end
    end

    defmodule #{second_module} do
      def normalize(items) do
        items
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
      end
    end
    """
  end

  defp analyze(project, path, old_source, new_source, config \\ []) do
    range = full_range(old_source, new_source)
    config = Keyword.merge([clone_analysis: [provider: false]], config)

    Displacement.analyze(project, "HEAD", %{path => [range]}, config,
      old_sources: %{path => old_source},
      new_sources: %{path => new_source}
    )
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
        "reach-displacement-#{System.unique_integer([:positive])}.ex"
      )

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)
    {Reach.Project.from_sources([path]), path}
  end
end
