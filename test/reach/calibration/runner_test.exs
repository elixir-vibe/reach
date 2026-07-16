defmodule Reach.Calibration.RunnerTest.FakeClient do
  @behaviour Reach.Calibration.Source

  def package_versions(_opts) do
    {:ok, [%{"ecosystem" => "hex", "package_name" => "demo", "version" => "1.0.0"}]}
  end

  def hydrate(_version, _opts) do
    {:ok,
     %{
       "fingerprint" => "snapshot-1",
       "package_version" => %{
         "ecosystem" => "hex",
         "package_name" => "demo",
         "version" => "1.0.0"
       },
       "files" => [
         %{
           "path" => "lib/demo.ex",
           "source" => """
           defmodule Demo do
             def fetch(map, key, default) do
               Map.get(map, key) || Map.get(map, Atom.to_string(key)) || default
             end
           end
           """
         }
       ]
     }}
  end
end

defmodule Reach.Calibration.RunnerTest do
  use ExUnit.Case, async: true

  alias Reach.Calibration.Runner
  alias Reach.Calibration.RunnerTest.FakeClient

  @opts [
    client: FakeClient,
    plugins: [],
    kinds: MapSet.new([:dual_key_fallback])
  ]

  test "produces stable review IDs and unreviewed metrics" do
    assert {:ok, report} = Runner.run(@opts)
    assert report["selection"]["kinds"] == ["dual_key_fallback"]
    assert report["selection"]["paths"] == nil
    assert report["selection"]["hydration_scope"] == "candidate_paths_or_lib"
    assert report["summary"]["packages"] == 1
    assert report["summary"]["errors"] == 0

    [finding | _rest] = get_in(report, ["packages", Access.at(0), "findings"])
    assert byte_size(finding["id"]) == 64
    assert finding["verdict"] == "unreviewed"

    metrics = report["summary"]["by_kind"]["dual_key_fallback"]
    assert metrics["reviewed"] == 0
    assert metrics["precision"] == nil
  end

  test "computes precision from reviewed labels" do
    assert {:ok, initial} = Runner.run(@opts)
    [finding | _rest] = get_in(initial, ["packages", Access.at(0), "findings"])

    labels_path =
      Path.join(System.tmp_dir!(), "reach-labels-#{System.unique_integer([:positive])}.json")

    File.write!(labels_path, JSON.encode!(%{finding["id"] => "true_positive"}))
    on_exit(fn -> File.rm(labels_path) end)

    assert {:ok, report} = Runner.run(Keyword.put(@opts, :labels, labels_path))
    metrics = report["summary"]["by_kind"]["dual_key_fallback"]

    assert metrics["reviewed"] == 1
    assert metrics["true_positives"] == 1
    assert metrics["false_positives"] == 0
    assert metrics["precision"] == 1.0
  end
end
