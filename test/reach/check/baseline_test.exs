defmodule Reach.Check.BaselineTest do
  use ExUnit.Case, async: true

  alias Reach.Check.AnalysisScope
  alias Reach.Check.Baseline
  alias Reach.Check.Finding
  alias Reach.Check.Violation
  alias Reach.Smell

  test "writes and filters known findings" do
    path = baseline_path()
    known = finding("known")
    new = finding("new")

    Baseline.write(path, :smells, [known])

    assert {[^new], [^known]} = Baseline.filter([known, new], path)
  after
    cleanup_baseline()
  end

  test "rewrites only the selected source" do
    path = baseline_path()
    arch = %Finding{finding("arch") | source: :arch}
    old_smell = %Finding{finding("old-smell") | source: :smells}
    new_smell = %Finding{finding("new-smell") | source: :smells}

    Baseline.write(path, :arch, [arch])
    Baseline.write(path, :smells, [old_smell])
    Baseline.write(path, :smells, [new_smell])

    baseline = Baseline.read(path)

    assert Enum.map(baseline.findings, & &1.fingerprint) |> Enum.sort() ==
             Enum.map([arch, new_smell], & &1.fingerprint) |> Enum.sort()
  after
    cleanup_baseline()
  end

  test "records analysis scopes and rejects incompatible reuse" do
    path = baseline_path()
    dev_scope = scope("dev", ["lib"], 1)
    test_scope = scope("test", ["lib", "test/support"], 2)

    Baseline.write(path, :arch, [finding("known")], dev_scope)

    baseline = Baseline.read(path)
    assert baseline.version == 2
    assert baseline.scopes["arch"] == dev_scope
    assert Baseline.validate_scope(path, :arch, dev_scope) == :ok

    assert {:error, message} = Baseline.validate_scope(path, :arch, test_scope)
    assert message =~ "different analysis scope"
    assert message =~ "MIX_ENV=dev"
    assert message =~ "MIX_ENV=test"
  after
    cleanup_baseline()
  end

  test "a missing baseline has no scope mismatch" do
    path = baseline_path()
    assert Baseline.validate_scope(path, :arch, scope("dev", ["lib"], 1)) == :ok
  after
    cleanup_baseline()
  end

  test "scope compatibility ignores file count changes" do
    path = baseline_path()
    original = scope("test", ["lib", "test/support"], 2)
    changed_tree = scope("test", ["lib", "test/support"], 5)

    Baseline.write(path, :arch, [finding("known")], original)

    assert Baseline.validate_scope(path, :arch, changed_tree) == :ok
  after
    cleanup_baseline()
  end

  test "converts architecture violations to fingerprints" do
    violation =
      Violation.new(
        type: :forbidden_call,
        file: "lib/foo.ex",
        line: 12,
        caller_module: Foo,
        call: "Bar.baz/1",
        rule: "test"
      )

    finding = Finding.from_arch_violation(violation)

    assert finding.source == :arch
    assert finding.kind == :forbidden_call
    assert finding.file == "lib/foo.ex"
    assert finding.line == 12
    assert finding.fingerprint =~ "sha256:"
  end

  test "converts smell findings to stable fingerprints" do
    left =
      Smell.Finding.new(
        kind: :suboptimal,
        message: "use match?/2",
        location: "lib/foo.ex:10"
      )

    right =
      Smell.Finding.new(
        kind: :suboptimal,
        message: "use match?/2",
        location: "lib/foo.ex:99"
      )

    assert Finding.from_smell(left).fingerprint == Finding.from_smell(right).fingerprint
  end

  defp scope(env, roots, file_count) do
    AnalysisScope.new(
      source: :mix,
      mix_env: env,
      source_roots: roots,
      file_count: file_count
    )
  end

  defp finding(id) do
    %Finding{
      source: :smells,
      kind: :suboptimal,
      fingerprint: "sha256:" <> id,
      message: id,
      file: "lib/#{id}.ex",
      line: 1
    }
  end

  defp baseline_path do
    path = Path.join(System.tmp_dir!(), "reach-baseline-test-#{System.unique_integer()}.json")
    Process.put(:baseline_path, path)
    path
  end

  defp cleanup_baseline do
    if path = Process.get(:baseline_path), do: File.rm(path)
  end
end
