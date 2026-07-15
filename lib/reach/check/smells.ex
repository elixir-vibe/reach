defmodule Reach.Check.Smells do
  @moduledoc """
  Runs structural and performance smell checks over a loaded project.
  """

  alias Reach.{Config, Plugin}
  alias Reach.Smell.{DSLGuard, Registry, SourceRunner, Suppressions}

  def run(project, config \\ []) do
    config = Config.normalize(config)

    {pattern_checks, checks} =
      Enum.split_with(Reach.Smell.Registry.checks(project, config), &pattern_check?/1)

    findings =
      SourceRunner.run(project, pattern_checks) ++
        Enum.flat_map(checks, &run_check(&1, project, config))

    plugin_checks = project |> Map.get(:plugins, []) |> Plugin.smell_checks() |> MapSet.new()

    plugin_kinds =
      (pattern_checks ++ checks)
      |> Enum.filter(&MapSet.member?(plugin_checks, &1))
      |> Enum.flat_map(&Registry.kinds/1)
      |> MapSet.new()

    findings
    |> DSLGuard.filter(project, config, plugin_kinds)
    |> Suppressions.filter(project, config)
  end

  def analyze(project), do: run(project)

  defp pattern_check?(check) do
    Code.ensure_loaded?(check) and function_exported?(check, :__reach_pattern_check__, 0)
  end

  defp run_check(check, project, config) do
    if function_exported?(check, :run, 2),
      do: check.run(project, config),
      else: check.run(project)
  end
end
