defmodule Reach.Check.BoundaryContractCandidatesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Reach.Check.{BoundaryContractCandidates, Candidates}
  alias Reach.CLI.Render.Check, as: CheckRender
  alias Reach.Config
  alias Reach.Inspect.Candidates, as: InspectCandidates
  alias Reach.Project
  alias Reach.Project.Query

  test "builds an actionable boundary contract with draft and blast radius" do
    {project, path} =
      project("""
      defmodule PricingBoundary do
        def init(raw) do
          pricing = Jason.decode!(raw)
          :persistent_term.put(:pricing, pricing)
        end

        def total(pricing), do: pricing["input"] + pricing["output"]
        def quote(pricing), do: PricingBoundary.total(pricing)
      end
      """)

    assert [candidate] = BoundaryContractCandidates.build(project, candidate_config())

    assert candidate.id == "R10-001"
    assert candidate.kind == :introduce_boundary_contract
    assert candidate.target == "PricingBoundary.init/1 at :persistent_term.put/2"
    assert candidate.file == path
    assert candidate.line == 4
    assert candidate.confidence == :high
    assert candidate.benefit == :high
    assert candidate.risk == :medium
    assert candidate.decoder == "Jason.decode!/1"
    assert candidate.boundary == ":persistent_term.put/2"
    assert candidate.keys == ["input", "output"]

    assert candidate.canonical_site == %{
             target: "PricingBoundary.init/1 at :persistent_term.put/2",
             file: path,
             line: 4,
             reason: :normalization_boundary
           }

    assert candidate.draft_contract ==
             "@enforce_keys [:input, :output]\ndefstruct [:input, :output]"

    assert candidate.blast_radius == [
             "PricingBoundary.init/1",
             "PricingBoundary.total/1",
             "PricingBoundary.quote/1"
           ]

    assert Enum.any?(candidate.proof, &String.contains?(&1, "missing keys"))
    assert candidate.suggestion =~ "Normalize Jason.decode!/1 output"

    assert Enum.any?(
             Candidates.run(project, [], top: 100).candidates,
             &(&1.kind == :introduce_boundary_contract and &1.target == candidate.target)
           )

    mfa = {PricingBoundary, :total, 1}
    function = Query.find_function(project, mfa)

    assert Enum.any?(
             InspectCandidates.find(project, mfa, function, candidate_config()),
             &(&1.target == candidate.target)
           )

    output =
      capture_io(fn ->
        CheckRender.render_candidates_text(%{
          candidates: [candidate],
          note: "advisory"
        })
      end)

    assert output =~ "canonical site=PricingBoundary.init/1 at :persistent_term.put/2"
    assert output =~ "draft contract"
    assert output =~ "@enforce_keys [:input, :output]"
    assert output =~ "blast radius"
    assert output =~ "PricingBoundary.quote/1"

    json = candidate |> JSON.encode!() |> JSON.decode!()
    assert json["decoder"] == "Jason.decode!/1"
    assert json["boundary"] == ":persistent_term.put/2"
    assert json["canonical_site"]["reason"] == "normalization_boundary"
    assert json["draft_contract"] =~ "defstruct"
    assert "PricingBoundary.quote/1" in json["blast_radius"]
  end

  test "keeps dynamic decoded stores and normalized structs out of candidates" do
    {dynamic, _path} =
      project("""
      defmodule DynamicBoundary do
        use GenServer
        def init(raw), do: {:ok, Jason.decode!(raw)}
        def handle_call({:fetch, key}, _from, data), do: {:reply, Map.get(data, key), data}
      end
      """)

    assert BoundaryContractCandidates.build(dynamic, candidate_config()) == []

    {normalized, _path} =
      project("""
      defmodule NormalizedBoundary do
        defstruct [:input, :output]

        def init(raw) do
          decoded = Jason.decode!(raw)
          pricing = %__MODULE__{input: decoded["input"], output: decoded["output"]}
          :persistent_term.put(:pricing, pricing)
        end
      end
      """)

    assert BoundaryContractCandidates.build(normalized, candidate_config()) == []
  end

  test "falls back to a validation schema draft for non-field keys" do
    {project, _path} =
      project("""
      defmodule UnusualBoundary do
        def init(raw) do
          payload = Jason.decode!(raw)
          :persistent_term.put(:payload, payload)
        end

        def read(payload), do: payload["content-type"] || payload["x request"]
      end
      """)

    assert [candidate] = BoundaryContractCandidates.build(project, candidate_config())
    assert candidate.draft_contract =~ "validation schema"
    assert candidate.draft_contract =~ "content-type"
  end

  defp candidate_config, do: Config.normalize([]).candidates

  defp project(source) do
    path =
      Path.join(
        System.tmp_dir!(),
        "reach-boundary-contract-#{System.unique_integer([:positive])}.ex"
      )

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)
    {Project.from_sources([path], plugins: [Reach.Plugins.Jason]), path}
  end
end
