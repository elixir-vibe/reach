defmodule Reach.Smell.Checks.FalseSuccessErrorTest do
  use ExUnit.Case, async: true

  alias Reach.Check.Smells
  alias Reach.Smell.Finding

  test "flags check functions that convert errors into empty success" do
    project =
      project_from_string(~S'''
      defmodule Mix.Tasks.App.Check do
        def check_lint(source) do
          case Lint.run(source) do
            {:ok, diagnostics} -> diagnostics
            {:error, _errors} -> []
          end
        end
      end
      ''')

    assert [%Finding{kind: :false_success_error}] = Smells.run(project)
  end

  test "handles calls qualified through __MODULE__" do
    project =
      project_from_string(~S'''
      defmodule Validator do
        def validate_thing(arg) do
          case __MODULE__.Helper.run(arg) do
            {:ok, value} -> {:ok, value}
            {:error, _reason} -> :ok
          end
        end
      end
      ''')

    refute Enum.any?(Smells.run(project), &(&1.kind == :false_success_error))
  end

  test "detects suspicious module names qualified through __MODULE__" do
    project =
      project_from_string(~S'''
      defmodule Validator do
        def validate_thing(arg) do
          case __MODULE__.Lint.run(arg) do
            {:ok, value} -> value
            {:error, _reason} -> :ok
          end
        end
      end
      ''')

    assert [%Finding{kind: :false_success_error}] = Smells.run(project)
  end

  test "allows error propagation" do
    project =
      project_from_string(~S'''
      defmodule Mix.Tasks.App.Check do
        def check_lint(source) do
          case Lint.run(source) do
            {:ok, diagnostics} -> diagnostics
            {:error, errors} -> {:error, errors}
          end
        end
      end
      ''')

    refute Enum.any?(Smells.run(project), &(&1.kind == :false_success_error))
  end

  test "ignores non-check functions" do
    project =
      project_from_string(~S'''
      defmodule Parser do
        def normalize(result) do
          case result do
            {:ok, value} -> value
            {:error, _} -> []
          end
        end
      end
      ''')

    refute Enum.any?(Smells.run(project), &(&1.kind == :false_success_error))
  end

  defp project_from_string(source) do
    path = Path.join(System.tmp_dir!(), "reach-false-success-#{System.unique_integer()}.ex")
    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)
    Reach.Project.from_sources([path])
  end
end
