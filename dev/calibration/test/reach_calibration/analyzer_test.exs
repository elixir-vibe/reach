defmodule ReachCalibration.AnalyzerTest do
  use ExUnit.Case, async: true

  alias ReachCalibration.Analyzer

  test "runs selected Reach checks against hydrated files" do
    snapshot =
      snapshot("lib/demo.ex", """
      defmodule Demo do
        def fetch(map, key, default) do
          Map.get(map, key) || Map.get(map, Atom.to_string(key)) || default
        end
      end
      """)

    kinds = MapSet.new([:dual_key_fallback, :false_collapsing_lookup])

    assert {:ok, result} = Analyzer.analyze(snapshot, plugins: [], kinds: kinds)
    assert result["package"] == "demo"
    assert result["snapshot_fingerprint"] == "snapshot-1"
    assert Enum.all?(result["findings"], &String.starts_with?(&1["location"], "lib/demo.ex:"))
    assert Enum.any?(result["findings"], &(&1["kind"] == "dual_key_fallback"))
  end

  test "rejects paths that escape the hydrated snapshot" do
    snapshot = snapshot("../outside.ex", "defmodule Outside do\nend\n")

    assert {:error, {:invalid_snapshot_path, "../outside.ex"}} = Analyzer.analyze(snapshot)
  end

  defp snapshot(path, source) do
    %{
      "fingerprint" => "snapshot-1",
      "package_version" => %{
        "ecosystem" => "hex",
        "package_name" => "demo",
        "version" => "1.0.0"
      },
      "files" => [%{"path" => path, "source" => source}]
    }
  end
end
