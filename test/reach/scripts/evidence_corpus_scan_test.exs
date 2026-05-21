defmodule Reach.Scripts.EvidenceCorpusScanTest do
  use ExUnit.Case, async: true

  test "evidence corpus scanner supports text and json output" do
    dir =
      Path.join(System.tmp_dir!(), "reach-evidence-scan-#{System.unique_integer([:positive])}")

    lib = Path.join(dir, "lib")
    File.mkdir_p!(lib)

    File.write!(Path.join(lib, "sample.ex"), """
    defmodule Sample do
      def run(items), do: items |> Enum.map(&List.wrap/1) |> List.flatten()
    end
    """)

    assert {text, 0} = scan(["--kind", "stdlib", dir])
    assert text =~ "manual_flat_map=1"

    assert {json, 0} = scan(["--kind", "stdlib", "--format", "json", dir])
    assert [result] = Jason.decode!(json)
    assert result["kind"] == "manual_flat_map"
    assert result["family"] == "stdlib"

    File.rm_rf(dir)
  end

  test "evidence corpus scanner suppresses parser warnings" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "reach-evidence-warning-scan-#{System.unique_integer([:positive])}"
      )

    lib = Path.join(dir, "lib")
    File.mkdir_p!(lib)

    File.write!(Path.join(lib, "sample.ex"), """
    defmodule Sample do
      def deprecated_escape, do: "\\x{FF}"
      def charlist, do: 'abc'
      def run(items), do: items |> Enum.map(&List.wrap/1) |> List.flatten()
    end
    """)

    assert {json, 0} = scan(["--kind", "stdlib", "--format", "json", dir])
    assert [_result] = Jason.decode!(json)
    refute json =~ "warning:"

    File.rm_rf(dir)
  end

  test "evidence corpus scanner includes map-contract structured fields" do
    dir = Path.join(System.tmp_dir!(), "reach-map-scan-#{System.unique_integer([:positive])}")
    lib = Path.join(dir, "lib")
    File.mkdir_p!(lib)

    File.write!(Path.join(lib, "sample.ex"), """
    defmodule Sample do
      def build(user) do
        data = %{id: user.id, name: user.name, email: user.email}
        data.id
        data.email
      end
    end
    """)

    assert {json, 0} = scan(["--kind", "map-contract", "--format", "json", dir])
    assert [result] = Jason.decode!(json)
    assert result["family"] == "map_contract"
    assert result["keys"] == ["email", "id", "name"]
    assert result["variable"] == "data"
    assert result["role"] == "unknown"
    assert result["observed_keys"] == ["email", "id"]
    assert result["unused_keys"] == ["name"]
    assert result["read_count"] == 2
    assert result["mutation_count"] == 0
    assert result["escaped?"] == false
    assert_in_delta result["key_coverage"], 2 / 3, 0.001

    File.rm_rf(dir)
  end

  test "evidence corpus scanner applies plugin refinements" do
    dir =
      Path.join(System.tmp_dir!(), "reach-map-refine-scan-#{System.unique_integer([:positive])}")

    lib = Path.join(dir, "lib")
    File.mkdir_p!(lib)

    File.write!(Path.join(lib, "sample.ex"), """
    defmodule Sample do
      def build(user) do
        data = %{id: user.id, name: user.name, email: user.email}
        data.id
        data.email
        Jason.encode!(data)
      end
    end
    """)

    assert {json, 0} = scan(["--kind", "map-contract", "--format", "json", dir])
    assert [result] = Jason.decode!(json)
    assert result["role"] == "external_payload"

    assert [%{"module" => "Elixir.Jason", "function" => "encode!", "arity" => 1}] =
             result["escapes"]

    File.rm_rf(dir)
  end

  defp scan(args) do
    System.cmd("mix", ["run", "scripts/evidence_corpus_scan.exs", "--" | args],
      stderr_to_stdout: true
    )
  end
end
