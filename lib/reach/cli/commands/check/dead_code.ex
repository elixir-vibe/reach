defmodule Reach.CLI.Commands.Check.DeadCode do
  @moduledoc false

  alias Reach.Check.AnalysisScope
  alias Reach.Check.DeadCode, as: DeadCodeCheck
  alias Reach.CLI.Project
  alias Reach.CLI.Render.Check.DeadCode, as: DeadCodeRender

  def run(opts, positional, command \\ "reach.check") do
    format = opts[:format] || "text"

    Project.compile(format == "json" or opts[:multi_check?] == true)

    requested_paths = opts[:paths] || opts[:path] || List.first(positional)
    files = DeadCodeCheck.collect_files(requested_paths)
    unless opts[:project], do: register_scope(requested_paths, files)

    unless format == "json" or opts[:multi_check?] do
      Mix.shell().info("Analyzing project...")

      Mix.shell().info("Analysis scope: #{AnalysisScope.describe(Project.analysis_scope())}")
    end

    findings = DeadCodeCheck.run(files, Keyword.take(opts, [:plugins]))
    DeadCodeRender.render(findings, format, command, Project.analysis_scope())
  end

  defp register_scope(nil, files) do
    %{roots: roots} = Reach.Project.mix_source_files()
    Project.register_analysis_scope(:mix, roots, files, Mix.env())
  end

  defp register_scope(paths, files) do
    Project.register_analysis_scope(:paths, List.wrap(paths), files)
  end
end
