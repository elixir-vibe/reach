defmodule Reach.Test.ProgramFacts.CLI do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.CaptureIO

  alias Reach.Test.ProgramFacts.Project

  def run_json(program, task, args) when is_atom(task) and is_list(args) do
    Project.with_project(program, fn _dir, _project ->
      fn -> task.run(args ++ ["--format", "json"]) end
      |> capture_task()
      |> decode_json()
    end)
  end

  def run_json_expect_raise(program, task, args, exception, pattern)
      when is_atom(task) and is_list(args) do
    Project.with_project(program, fn _dir, _project ->
      task_fun = fn -> task.run(args ++ ["--format", "json"]) end
      assert_fun = fn -> assert_raise exception, pattern, task_fun end

      assert_fun
      |> capture_io()
      |> decode_json()
    end)
  end

  defp capture_task(fun) when is_function(fun, 0), do: capture_io(fun)

  defp decode_json(output) do
    json =
      output
      |> String.split("\n")
      |> Enum.drop_while(&(not String.starts_with?(&1, "{")))
      |> Enum.join("\n")

    case Jason.decode(json) do
      {:ok, data} -> data
      {:error, error} -> raise "invalid JSON CLI output: #{inspect(error)}"
    end
  end
end
