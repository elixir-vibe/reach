defmodule Reach.Check.CloneConsolidationCandidatesTest do
  use ExUnit.Case, async: true

  alias Reach.Check.CloneConsolidationCandidates
  alias Reach.Config
  alias Reach.Evidence.CloneAnalysis.{Clone, Fragment}
  alias Reach.Map.Analysis, as: MapAnalysis

  test "selects the more complete exact clone as the canonical implementation" do
    project = project_fixture()
    config = Config.normalize([])

    clone =
      exact_clone(
        fragment(Core, :normalize, 1, 3),
        fragment(Feature, :normalize, 1, 9, validation_calls: [{Feature, :validate, 1}])
      )

    assert [candidate] = CloneConsolidationCandidates.build([clone], project, config)
    assert candidate.kind == :consolidate_clone
    assert candidate.target == "Feature.normalize/1"
    assert candidate.confidence == :high
    assert candidate.actionability == :needs_behavior_equivalence
    assert candidate.occurrences == 2
    assert [%{id: "Core.normalize/1"}] = candidate.clone_siblings
    assert candidate.suggestion =~ "Feature.normalize/1"
  end

  test "uses direct callers as a deterministic tie-breaker" do
    project = project_fixture()
    config = Config.normalize([])

    clone = exact_clone(fragment(Core, :normalize, 1, 3), fragment(Feature, :normalize, 1, 9))

    assert [%{target: "Core.normalize/1"}] =
             CloneConsolidationCandidates.build([clone], project, config)
  end

  test "module coupling attributes calls to the owning module in shared files" do
    coupling = project_fixture() |> MapAnalysis.module_coupling() |> Map.new(&{&1.name, &1})

    assert coupling["Client"].efferent == 1
    assert coupling["Feature"].efferent == 0
    assert coupling["Core"].afferent == 1
  end

  test "excludes clone functions owned by intentional behaviour modules" do
    project =
      project_from_source("""
      defmodule Core do
        def normalize(value), do: value
      end

      defmodule Adapter do
        @behaviour Access
        def normalize(value), do: value
      end
      """)

    clone = exact_clone(fragment(Core, :normalize, 1, 2), fragment(Adapter, :normalize, 1, 7))

    assert [] = CloneConsolidationCandidates.build([clone], project, Config.normalize([]))
  end

  test "keeps expression-level exact clones as evidence only" do
    project = project_fixture()

    clone =
      exact_clone(
        fragment(Core, :normalize, 1, 3),
        fragment(Feature, :normalize, 1, 9, whole_function: false)
      )

    assert [] = CloneConsolidationCandidates.build([clone], project, Config.normalize([]))
  end

  test "keeps non-Type-I clones as evidence only" do
    project = project_fixture()
    config = Config.normalize([])

    clone = %{
      exact_clone(fragment(Core, :normalize, 1, 3), fragment(Feature, :normalize, 1, 9))
      | type: :type_iii,
        similarity: 0.95
    }

    assert [] = CloneConsolidationCandidates.build([clone], project, config)
  end

  defp exact_clone(left, right) do
    Clone.new(
      type: :type_i,
      mass: 40,
      similarity: nil,
      fragments: [left, right]
    )
  end

  defp fragment(module, function, arity, line, attrs \\ []) do
    defaults = [
      file: source_path(),
      line: line,
      origin: :project,
      module: module,
      function: function,
      arity: arity,
      effects: [],
      effect_sequence: [],
      validation_calls: [],
      return_shapes: [],
      whole_function: true
    ]

    defaults
    |> Keyword.merge(attrs)
    |> Fragment.new()
  end

  defp project_fixture do
    project_from_source("""
    defmodule Core do
      def normalize(value), do: value
    end

    defmodule Client do
      def run(value), do: Core.normalize(value)
    end

    defmodule Feature do
      def normalize(value), do: value
    end
    """)
  end

  defp project_from_source(source) do
    path = source_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
    on_exit(fn -> File.rm_rf(Path.dirname(path)) end)
    Reach.Project.from_sources([path])
  end

  defp source_path do
    Path.join(
      System.tmp_dir!(),
      "reach-clone-candidate-#{System.unique_integer([:positive])}/sample.ex"
    )
  end
end
