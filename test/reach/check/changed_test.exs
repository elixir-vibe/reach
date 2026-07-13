defmodule Reach.Check.ChangedTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Mix.Tasks.Reach.Check
  alias Reach.Check.Changed
  alias Reach.Check.Changed.Range
  alias Reach.CLI.Render.Check, as: CheckRender
  alias Reach.Project.Query

  test "changed analysis reports cloned sibling functions" do
    in_tmp_git_repo(fn repo ->
      file = Path.join(repo, "lib/example.ex")
      File.mkdir_p!(Path.dirname(file))

      File.write!(file, """
      defmodule ExampleA do
        def normalize(value) do
          value = String.trim(value)
          {:ok, value}
        end
      end

      defmodule ExampleB do
        def normalize(value) do
          value = String.trim(value)
          {:ok, value}
        end
      end
      """)

      git!(repo, ["add", "."])
      git!(repo, ["commit", "-m", "initial"])

      File.write!(file, """
      defmodule ExampleA do
        def normalize(value) do
          value = String.trim(value)
          {:ok, value}
        end
      end

      defmodule ExampleB do
        def normalize(value) do
          value = String.trim(value)
          {:ok, String.downcase(value)}
        end
      end
      """)

      git!(repo, ["add", "."])
      git!(repo, ["commit", "-m", "change clone"])

      project = Reach.Project.from_sources([file])

      result =
        File.cd!(repo, fn ->
          Changed.run(project, [clone_analysis: [min_mass: 3, min_similarity: 0.5]],
            base: "HEAD~1"
          )
        end)

      assert [%{id: "ExampleB.normalize/1", clone_siblings: [_ | _]}] = result.changed_functions
    end)
  end

  test "changed analysis selects functions from large ranges without expanding every line" do
    in_tmp_git_repo(fn repo ->
      file = Path.join(repo, "lib/large_range.ex")
      File.mkdir_p!(Path.dirname(file))

      File.write!(file, """
      defmodule LargeRange do
        def first do
          :first
        end

        def second do
          :second
        end
      end
      """)

      project = Reach.Project.from_sources([file], plugins: [])

      functions =
        Changed.changed_functions(project, %{"lib/large_range.ex" => [{3, 1_000_000}]}, [])

      assert Enum.map(functions, & &1.id) == ["LargeRange.first/0", "LargeRange.second/0"]
    end)
  end

  test "range lookup preserves point lookup semantics" do
    in_tmp_git_repo(fn repo ->
      file = Path.join(repo, "lib/range_semantics.ex")
      File.mkdir_p!(Path.dirname(file))

      File.write!(file, """
      defmodule RangeSemantics do
        def first, do: :first
        def second, do: :second
        def third, do: :third
      end
      """)

      project = Reach.Project.from_sources([file], plugins: [])
      ranges = %{"lib/range_semantics.ex" => [{2, 2}, {4, 5}]}

      expected =
        ranges
        |> Enum.flat_map(fn {path, path_ranges} ->
          path_ranges
          |> Enum.flat_map(fn {first, last} -> first..last end)
          |> Enum.map(&Query.find_function_at_location(project, path, &1))
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq_by(& &1.id)

      assert Enum.map(Query.functions_in_ranges(project, ranges), & &1.id) ==
               Enum.map(expected, & &1.id)
    end)
  end

  test "changed analysis includes the function preceding a body-only range" do
    in_tmp_git_repo(fn repo ->
      file = Path.join(repo, "lib/body_change.ex")
      File.mkdir_p!(Path.dirname(file))

      File.write!(file, """
      defmodule BodyChange do
        def first do
          :first
        end

        def second do
          :second
        end
      end
      """)

      project = Reach.Project.from_sources([file], plugins: [])

      assert [%{id: "BodyChange.second/0"}] =
               Changed.changed_functions(project, %{"lib/body_change.ex" => [{7, 7}]}, [])
    end)
  end

  test "changed analysis reports high confidence for fully assessed ranges" do
    in_tmp_git_repo(fn repo ->
      file = Path.join(repo, "lib/covered.ex")
      File.mkdir_p!(Path.dirname(file))

      File.write!(file, """
      defmodule Covered do
        def run do
          :ok
        end
      end
      """)

      project = Reach.Project.from_sources([file], plugins: [])

      result =
        Changed.run(project, [],
          base: "HEAD",
          files: ["lib/covered.ex"],
          changed_ranges: %{
            "lib/covered.ex" => [
              Range.new(old_start: 2, old_count: 0, new_start: 2, new_count: 3)
            ]
          }
        )

      assert result.risk == :low
      assert result.confidence == :high
      assert result.coverage.coverage_percent == 100.0
      assert result.coverage.assessed_line_count == 3
      assert result.coverage.unassessed_files == []
    end)
  end

  test "changed analysis separates partial coverage from low risk" do
    in_tmp_git_repo(fn repo ->
      file = Path.join(repo, "lib/partial.ex")
      File.mkdir_p!(Path.dirname(file))

      File.write!(file, """
      defmodule Partial do
        @moduledoc false

        # setup outside a function
        def run do
          :ok
        end
      end
      """)

      project = Reach.Project.from_sources([file], plugins: [])

      result =
        Changed.run(project, [],
          base: "HEAD",
          files: ["lib/partial.ex"],
          changed_ranges: %{
            "lib/partial.ex" => [
              Range.new(old_start: 2, old_count: 0, new_start: 2, new_count: 5)
            ]
          }
        )

      assert result.risk == :low
      assert result.confidence == :partial
      assert result.coverage.assessed_line_count == 2
      assert result.coverage.unassessed_line_count == 3
      assert result.coverage.coverage_percent == 40.0
      assert result.coverage.partially_assessed_file_count == 1
      assert result.coverage.unassessed_files == ["lib/partial.ex"]
    end)
  end

  test "non-source changes are explicitly unassessed in text output" do
    in_tmp_git_repo(fn repo ->
      file = Path.join(repo, "lib/example.ex")
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, "defmodule CoverageExample do\n  def run, do: :ok\nend\n")
      project = Reach.Project.from_sources([file], plugins: [])

      result =
        Changed.run(project, [],
          base: "HEAD",
          files: ["README.md"],
          changed_ranges: %{
            "README.md" => [
              Range.new(old_start: 1, old_count: 0, new_start: 1, new_count: 10)
            ]
          }
        )

      assert result.risk == :low
      assert result.confidence == :none
      assert result.coverage.coverage_percent == 0.0
      assert result.coverage.unassessed_files == ["README.md"]

      output = capture_io(fn -> CheckRender.render_changed_text(result) end)
      assert output =~ "risk=low confidence=none"
      assert output =~ "coverage=0.0% lines=0/10 assessed"
      assert output =~ "Unassessed files (1)"
      assert output =~ "README.md"
    end)
  end

  test "deleted-only changes remain unassessed instead of appearing confidently low-risk" do
    in_tmp_git_repo(fn repo ->
      file = Path.join(repo, "lib/current.ex")
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, "defmodule Current do\n  def run, do: :ok\nend\n")
      project = Reach.Project.from_sources([file], plugins: [])

      result =
        Changed.run(project, [],
          base: "HEAD",
          files: ["lib/deleted.ex"],
          changed_ranges: %{
            "lib/deleted.ex" => [
              Range.new(old_start: 1, old_count: 3, new_start: 0, new_count: 0)
            ]
          }
        )

      assert result.risk == :low
      assert result.confidence == :none
      assert result.coverage.changed_line_count == 3
      assert result.coverage.assessed_line_count == 0
      assert result.coverage.deleted_line_count == 3
      assert result.coverage.unassessed_files == ["lib/deleted.ex"]
    end)
  end

  test "changed ranges retain deleted-only hunks" do
    in_tmp_git_repo(fn repo ->
      file = Path.join(repo, "lib/deleted.ex")
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, "defmodule Deleted do\n  def run, do: :ok\nend\n")
      git!(repo, ["add", "."])
      git!(repo, ["commit", "-m", "initial"])
      File.rm!(file)
      git!(repo, ["add", "-A"])
      git!(repo, ["commit", "-m", "delete source"])

      ranges = File.cd!(repo, fn -> Changed.changed_ranges("HEAD~1") end)

      assert %{
               "lib/deleted.ex" => [
                 %Range{old_count: 3, new_count: 0}
               ]
             } = ranges
    end)
  end

  test "reach.check changed mode reports files, functions, and coverage" do
    output =
      capture_io(fn -> Check.run(["--changed", "--base", "HEAD", "--format", "json"]) end)

    json =
      output
      |> String.split("\n")
      |> Enum.drop_while(&(not String.starts_with?(&1, "{")))
      |> Enum.join("\n")

    assert {:ok, data} = JSON.decode(json)
    assert is_list(data["changed_files"])
    assert is_list(data["changed_functions"])
    assert data["confidence"] == "high"
    assert data["coverage"]["coverage_percent"] == 100.0
    assert data["coverage"]["unassessed_files"] == []
  end

  defp in_tmp_git_repo(fun) do
    repo =
      Path.join(System.tmp_dir!(), "reach_changed_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(repo)

    try do
      git!(repo, ["init"])
      git!(repo, ["config", "user.email", "reach@example.invalid"])
      git!(repo, ["config", "user.name", "Reach Test"])
      fun.(repo)
    after
      File.rm_rf!(repo)
    end
  end

  defp git!(repo, args) do
    case System.cmd("git", args, cd: repo, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end
end
