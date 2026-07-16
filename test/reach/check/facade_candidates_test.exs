defmodule Reach.Check.FacadeCandidatesTest do
  use ExUnit.Case, async: true

  alias Reach.Check.{Candidates, FacadeCandidates}
  alias Reach.Config
  alias Reach.Evidence.Facade.{Forwarder, Module}

  test "builds an advisory candidate for a concentrated forwarding module" do
    config = Config.normalize([])

    assert [candidate] = FacadeCandidates.build([facade_evidence()], config)
    assert candidate.kind == :review_facade
    assert candidate.target =~ "MyApp.API forwards 4/4"
    assert candidate.confidence == :high
    assert candidate.actionability == :needs_boundary_intent_review
    assert length(candidate.representative_calls) == 4
    assert candidate.suggestion =~ "boundaries[:public]"
  end

  test "keeps documented facades advisory at medium confidence" do
    config = Config.normalize([])
    facade = %{facade_evidence() | documented: true}
    assert [%{confidence: :medium}] = FacadeCandidates.build([facade], config)
  end

  test "suppresses modules declared as intentional public boundaries" do
    config = Config.normalize(boundaries: [public: ["MyApp.API"]])
    assert [] = FacadeCandidates.build([facade_evidence()], config)
  end

  test "suppresses behaviour, use, and deprecated compatibility modules" do
    config = Config.normalize([])
    facade = %{facade_evidence() | boundary_markers: [:behaviour]}
    assert [] = FacadeCandidates.build([facade], config)
  end

  test "candidate orchestration includes facade evidence" do
    project =
      project_from_source("""
      defmodule MyApp.API do
        defdelegate one(value), to: MyApp.Impl
        defdelegate two(value), to: MyApp.Impl
        defdelegate three(value), to: MyApp.Impl
      end
      """)

    result = Candidates.run(project, clone_analysis: [provider: false])
    assert Enum.any?(result.candidates, &(&1.kind == :review_facade))
  end

  defp facade_evidence do
    forwarders =
      for {function, line} <- Enum.with_index([:one, :two, :three, :four], 2) do
        %Forwarder{
          function: function,
          arity: 1,
          target_module: "MyApp.Impl",
          target_function: function,
          target_arity: 1,
          file: "/project/lib/api.ex",
          line: line,
          kind: :defdelegate
        }
      end

    %Module{
      module: "MyApp.API",
      file: "/project/lib/api.ex",
      line: 1,
      public_function_count: 4,
      forwarder_count: 4,
      forwarder_ratio: 1.0,
      target_modules: ["MyApp.Impl"],
      forwarders: forwarders,
      documented: false
    }
  end

  defp project_from_source(source) do
    dir =
      Path.join(System.tmp_dir!(), "reach-facade-candidate-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    path = Path.join(dir, "sample.ex")
    File.write!(path, source)
    on_exit(fn -> File.rm_rf(dir) end)
    Reach.Project.from_sources([path])
  end
end
