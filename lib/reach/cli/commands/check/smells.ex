defmodule Reach.CLI.Commands.Check.Smells do
  @moduledoc false

  alias Reach.Check.Baseline
  alias Reach.Check.Finding
  alias Reach.Check.Smells, as: SmellsCheck
  alias Reach.CLI.Project
  alias Reach.CLI.Render.Check.Smells, as: SmellsRender
  alias Reach.Config

  def run(opts, positional, command \\ "reach.check") do
    format = opts[:format] || "text"
    config = Config.read() |> Config.normalize()
    project = load_project(opts, positional)
    if is_nil(opts[:project]), do: :erlang.garbage_collect()
    findings = SmellsCheck.run(project, config)
    check_findings = Enum.map(findings, &Finding.from_smell/1)

    scope = Project.analysis_scope()
    write_baseline(opts, check_findings, scope)

    {findings, baseline_findings} =
      filter_baseline(findings, check_findings, opts, config, scope)

    SmellsRender.render(findings, format, command, scope)
    render_baseline_summary(baseline_findings, format)
    raise_on_strict_findings(findings, opts, config)
  end

  defp load_project(opts, positional) do
    path = opts[:path] || List.first(positional)

    project_opts =
      [quiet: opts[:format] == "json", show_scope: true, retain_module_sdgs: false] ++
        Keyword.take(opts, [:plugins, :paths])

    project_opts = if path, do: Keyword.put(project_opts, :paths, [path]), else: project_opts
    opts[:project] || Project.load(project_opts)
  end

  defp write_baseline(opts, check_findings, scope) do
    if write_path = Baseline.write_path(opts) do
      Baseline.write(write_path, :smells, check_findings, scope)
    end
  end

  defp filter_baseline(findings, check_findings, opts, config, scope) do
    path = Baseline.path(opts, config)
    validate_baseline_scope!(path, scope)
    {new_check_findings, baseline_findings} = Baseline.filter(check_findings, path)

    {filter_findings(findings, new_check_findings), baseline_findings}
  end

  defp validate_baseline_scope!(path, scope) do
    case Baseline.validate_scope(path, :smells, scope) do
      :ok ->
        :ok

      :legacy ->
        Mix.raise(
          "Baseline #{path} has no analysis scope metadata. Regenerate it with --write-baseline before reuse."
        )

      {:error, message} ->
        Mix.raise(message)
    end
  end

  defp render_baseline_summary([], _format), do: :ok
  defp render_baseline_summary(_baseline_findings, "json"), do: :ok

  defp render_baseline_summary(baseline_findings, _format) do
    IO.puts("#{length(baseline_findings)} baseline finding(s) suppressed")
  end

  defp raise_on_strict_findings([], _opts, _config), do: :ok

  defp raise_on_strict_findings(findings, opts, config) do
    if strict?(opts, config) do
      Mix.raise("Smell check failed: #{length(findings)} finding(s)")
    end
  end

  defp strict?(opts, config), do: opts[:strict] || config.smells.strict

  defp filter_findings(findings, check_findings) do
    allowed = MapSet.new(Enum.map(check_findings, & &1.fingerprint))

    Enum.filter(findings, fn finding ->
      finding
      |> Finding.from_smell()
      |> then(&MapSet.member?(allowed, &1.fingerprint))
    end)
  end
end
