defmodule Reach.Check.DependencyBypassCandidatesTest do
  use ExUnit.Case, async: true

  alias Reach.Check.DependencyBypassCandidates
  alias Reach.Config
  alias Reach.Evidence.Bypass
  alias Reach.Evidence.CloneAnalysis.{Clone, Fragment}

  test "promotes exact dependency clones and leaves weaker evidence unpromoted" do
    exact_fact = clone_fact(:type_i, nil, 12)
    weaker_fact = clone_fact(:type_iii, 0.92, 30)
    config = Config.normalize([]).candidates

    assert [candidate] = DependencyBypassCandidates.build([weaker_fact, exact_fact], config)
    assert candidate.kind == :reuse_dependency
    assert candidate.target == "MyApp.Parser.parse/1 duplicates sample_dep source"
    assert candidate.file == "/project/lib/parser.ex"
    assert candidate.line == 12
    assert candidate.confidence == :high
    assert candidate.actionability == :needs_dependency_api_review
    assert "dependency=sample_dep" in candidate.evidence
    assert candidate.suggestion =~ "public API"
  end

  test "respects the configured per-kind candidate limit" do
    config = Config.normalize(candidates: [limits: [per_kind: 1]]).candidates

    assert [_candidate] =
             DependencyBypassCandidates.build(
               [clone_fact(:type_i, nil, 20), clone_fact(:type_i, nil, 10)],
               config
             )
  end

  defp clone_fact(type, similarity, line) do
    clone =
      Clone.new(
        type: type,
        mass: 40,
        similarity: similarity,
        fragments: [
          Fragment.new(
            file: "/project/lib/parser.ex",
            line: line,
            origin: :project,
            module: MyApp.Parser,
            function: :parse,
            arity: 1
          ),
          Fragment.new(
            file: "/project/deps/sample_dep/lib/parser.ex",
            line: 5,
            origin: :dependency,
            dependency: :sample_dep
          )
        ]
      )

    [fact] = Bypass.from_dependency_clones([clone])
    fact
  end
end
