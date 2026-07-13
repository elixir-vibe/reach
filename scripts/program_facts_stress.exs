defmodule Reach.ProgramFactsStress do
  @moduledoc false

  alias Mix.Tasks.Reach.{Check, Inspect, Map, Otp, Trace}
  alias Reach.Test.ProgramFacts.Project, as: PFProject

  def run do
    Mix.Task.run("app.start")

    unless Code.ensure_loaded?(Reach.Test.ProgramFacts.Project) do
      Code.require_file("test/support/program_facts/project.ex", File.cwd!())
    end

    iterations =
      System.get_env("PROGRAM_FACTS_STRESS_ITERATIONS", "100")
      |> String.to_integer()

    seed =
      System.get_env("PROGRAM_FACTS_STRESS_SEED", "7000")
      |> String.to_integer()

    failure_root =
      System.get_env(
        "PROGRAM_FACTS_FAILURE_ROOT",
        Path.join(System.tmp_dir!(), "reach-program-facts-failures")
      )

    File.mkdir_p!(failure_root)

    search =
      ProgramFacts.Search.run(
        iterations: iterations,
        seed: seed,
        policies: ProgramFacts.policies(),
        layouts: ProgramFacts.layouts(),
        scoring: [:new_features, :graph_complexity, :cycles, :long_paths]
      )

    IO.puts(
      "ProgramFacts stress: candidates=#{search.coverage.candidate_count} kept=#{search.coverage.program_count} features=#{search.coverage.feature_count}"
    )

    Enum.each(search.programs, &run_program!(&1, failure_root))

    IO.puts("ProgramFacts stress completed successfully")
  end

  defp run_program!(program, failure_root) do
    try do
      PFProject.with_project(program, fn _dir, _project ->
        Enum.each(commands(program), fn {task_name, task, args, expected_command} ->
          data = run_json_task(task_name, task, args)

          unless data["command"] == expected_command do
            raise "expected #{expected_command}, got #{inspect(data["command"])} for #{inspect(args)}"
          end
        end)
      end)
    rescue
      exception ->
        save_failure!(failure_root, program, exception, __STACKTRACE__)
        reraise exception, __STACKTRACE__
    end
  end

  defp run_json_task(task_name, task, args) do
    Mix.Task.reenable(task_name)

    ExUnit.CaptureIO.capture_io(fn -> task.run(args) end)
    |> String.split("\n")
    |> Enum.drop_while(&(not String.starts_with?(&1, "{")))
    |> Enum.join("\n")
    |> JSON.decode!()
  end

  defp commands(program) do
    target = function_ref(List.first(program.facts.functions))
    line_target = line_ref(List.first(program.facts.locations.functions))
    why_target = why_target(program)

    [
      {"reach.map", Map, ["--format", "json"], "reach.map"},
      {"reach.map", Map, ["--modules", "--format", "json"], "reach.map"},
      {"reach.map", Map, ["--coupling", "--format", "json"], "reach.map"},
      {"reach.map", Map, ["--hotspots", "--format", "json", "--top", "20"], "reach.map"},
      {"reach.map", Map, ["--boundaries", "--format", "json"], "reach.map"},
      {"reach.map", Map, ["--data", "--format", "json", "--top", "20"], "reach.map"},
      {"reach.map", Map, ["--effects", "--format", "json"], "reach.map"},
      {"reach.map", Map, ["--depth", "--format", "json", "--top", "20"], "reach.map"},
      {"reach.trace", Trace, ["--variable", "input", "--format", "json"], "reach.trace"},
      {"reach.check", Check, ["--smells", "--format", "json"], "reach.check"},
      {"reach.check", Check, ["--candidates", "--format", "json", "--top", "10"], "reach.check"},
      {"reach.check", Check, ["--dead-code", "--format", "json"], "reach.check"},
      {"reach.otp", Otp, ["--format", "json"], "reach.otp"},
      {"reach.otp", Otp, ["--concurrency", "--format", "json"], "reach.otp"}
    ]
    |> maybe_add(target, &inspect_commands/1)
    |> maybe_add(line_target, &trace_slice_commands/1)
    |> maybe_add(why_target, fn {source, target} ->
      [{"reach.inspect", Inspect, [source, "--why", target, "--format", "json"], "reach.inspect"}]
    end)
  end

  defp inspect_commands(nil), do: []

  defp inspect_commands(target) do
    [
      {"reach.inspect", Inspect, [target, "--deps", "--format", "json"], "reach.inspect"},
      {"reach.inspect", Inspect, [target, "--impact", "--format", "json"], "reach.inspect"},
      {"reach.inspect", Inspect, [target, "--context", "--format", "json"], "reach.inspect"},
      {"reach.inspect", Inspect, [target, "--data", "--format", "json"], "reach.inspect"},
      {"reach.inspect", Inspect, [target, "--candidates", "--format", "json"], "reach.inspect"}
    ]
  end

  defp trace_slice_commands(nil), do: []

  defp trace_slice_commands(target) do
    [
      {"reach.trace", Trace, ["--backward", target, "--format", "json"], "reach.trace"},
      {"reach.trace", Trace, ["--forward", target, "--format", "json"], "reach.trace"}
    ]
  end

  defp maybe_add(commands, nil, _fun), do: commands
  defp maybe_add(commands, value, fun), do: commands ++ fun.(value)

  defp why_target(%{facts: %{call_paths: paths}}) do
    paths
    |> Enum.find(&(length(&1) >= 2))
    |> case do
      [source, target | _rest] -> {function_ref(source), function_ref(target)}
      _ -> nil
    end
  end

  defp function_ref(nil), do: nil
  defp function_ref({module, function, arity}), do: "#{inspect(module)}.#{function}/#{arity}"

  defp line_ref(nil), do: nil
  defp line_ref(%{file: file, line: line}), do: "#{file}:#{line}"

  defp save_failure!(root, program, exception, stacktrace) do
    dir =
      Path.join(
        root,
        "#{program.metadata.policy}-seed#{program.seed}-#{System.system_time(:millisecond)}"
      )

    ProgramFacts.Project.write!(dir, program, force: true)

    File.write!(
      Path.join(dir, "reach_failure.txt"),
      Exception.format(:error, exception, stacktrace) <>
        "\n\nReplay:\n  cd #{File.cwd!()} && PROGRAM_FACTS_FAILURE_ROOT=#{root} mix run scripts/program_facts_stress.exs\n"
    )

    IO.puts(:stderr, "saved ProgramFacts failure to #{dir}")
  end
end

Reach.ProgramFactsStress.run()
