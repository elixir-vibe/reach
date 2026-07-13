defmodule Reach.Check.ChangedTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Mix.Tasks.Reach.Check
  alias Reach.Check.Changed
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

  test "reach.check changed mode reports files and functions" do
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
