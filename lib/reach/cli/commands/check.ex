defmodule Reach.CLI.Commands.Check do
  @moduledoc """
  Runs structural validation and change-safety checks.

      mix reach.check
      mix reach.check --arch
      mix reach.check --changed --base main
      mix reach.check --dead-code
      mix reach.check --smells
      mix reach.check --candidates

  ## Options

    * `--format` — output format: `text` or `json`
    * `--arch` — check `.reach.exs` architecture policy
    * `--changed` — report changed functions and configured test hints
    * `--base` — git base ref for `--changed` (default: auto-detect `main`, `master`, or upstream)
    * `--dead-code` — find unused pure expressions
    * `--smells` — find graph/effect/data-flow performance smells
    * `--strict` — fail when smell findings are present (or set `smells: [strict: true]`)
    * `--baseline` — ignore known findings from a Reach baseline file
    * `--write-baseline` — write current findings to a Reach baseline file
    * `--candidates` — emit advisory refactoring candidates
    * `--top` — limit candidate output for `--candidates`

  """

  alias Reach.Check.Architecture
  alias Reach.Check.Architecture.Result, as: ArchitectureResult
  alias Reach.Check.Baseline
  alias Reach.Check.Candidates
  alias Reach.Check.Changed
  alias Reach.Check.Finding
  alias Reach.CLI.Commands.Check.DeadCode
  alias Reach.CLI.Commands.Check.Smells
  alias Reach.CLI.Project
  alias Reach.CLI.Render.Check, as: CheckRender
  alias Reach.Config

  @check_modes [:arch, :changed, :dead_code, :smells, :candidates]

  def run(opts, positional \\ []) do
    case selected_modes(opts) do
      [] -> run_default(opts)
      [mode] -> run_mode(mode, opts, positional)
      modes -> run_modes(modes, opts, positional)
    end
  end

  defp selected_modes(opts) do
    Enum.filter(@check_modes, &opts[&1])
  end

  defp run_modes(modes, opts, positional) do
    if opts[:format] == "json" do
      Mix.raise("JSON output supports one reach.check mode at a time")
    end

    opts = maybe_put_check_context(opts, modes, positional)
    Enum.each(modes, &run_mode(&1, opts, positional))
  end

  defp maybe_put_check_context(opts, modes, positional) do
    opts
    |> Keyword.put(:multi_check?, length(modes) > 1)
    |> maybe_put_shared_project(modes, positional)
  end

  defp maybe_put_shared_project(opts, modes, []) do
    if share_project?(opts, modes) do
      Keyword.put(opts, :project, Project.load([quiet: false] ++ plugin_opts(opts)))
    else
      opts
    end
  end

  defp maybe_put_shared_project(opts, _modes, _positional), do: opts

  defp share_project?(opts, modes) do
    is_nil(opts[:path]) and Enum.any?(modes, &(&1 in [:arch, :smells]))
  end

  defp run_mode(:arch, opts, _positional), do: run_arch(opts)
  defp run_mode(:changed, opts, _positional), do: run_changed(opts)
  defp run_mode(:dead_code, opts, positional), do: DeadCode.run(opts, positional, "reach.check")
  defp run_mode(:smells, opts, positional), do: Smells.run(opts, positional, "reach.check")
  defp run_mode(:candidates, opts, positional), do: run_candidates(opts, positional)

  defp run_default(opts) do
    if Config.read() != [] do
      run_arch(opts)
    else
      CheckRender.render_no_default()
    end
  end

  defp run_arch(opts) do
    config = Config.read!()

    result =
      case Architecture.config_violations(config) do
        [] ->
          project =
            opts[:project] || Project.load(quiet: opts[:format] == "json", source_only: true)

          Architecture.run(project, config)

        violations ->
          %ArchitectureResult{status: "failed", violations: violations}
      end

    config = Config.normalize(config)
    finding_count = length(result.violations)
    findings = Enum.map(result.violations, &Finding.from_arch_violation/1)

    if write_path = Baseline.write_path(opts) do
      Baseline.write(write_path, :arch, findings)
    end

    {new_findings, baseline_findings} = Baseline.filter(findings, Baseline.path(opts, config))
    violations = filter_violations(result.violations, new_findings)

    result = %{
      result
      | violations: violations,
        status: if(violations == [], do: "ok", else: "failed"),
        finding_count: finding_count,
        baseline_count: length(baseline_findings)
    }

    CheckRender.render_result(result, opts[:format], &CheckRender.render_arch_text/1)

    if result.violations != [] do
      Mix.raise("Architecture policy failed")
    end
  end

  defp filter_violations(violations, findings) do
    allowed = MapSet.new(Enum.map(findings, & &1.fingerprint))

    Enum.filter(violations, fn violation ->
      violation
      |> Finding.from_arch_violation()
      |> then(&MapSet.member?(allowed, &1.fingerprint))
    end)
  end

  defp run_changed(opts) do
    config = Config.read()
    base = opts[:base] || Changed.default_base_ref()
    files = Changed.changed_files(base)
    ranges = Changed.changed_ranges(base)

    result =
      if map_size(ranges) == 0 do
        Changed.empty_result(base, config, files)
      else
        project = Project.load([quiet: opts[:format] == "json"] ++ plugin_opts(opts))
        Changed.run(project, config, base: base, files: files, changed_ranges: ranges)
      end

    CheckRender.render_result(result, opts[:format], &CheckRender.render_changed_text/1)
  end

  defp run_candidates(opts, positional) do
    project = load_candidates_project(opts, positional)
    config = Config.read()
    result = Candidates.run(project, config, top: opts[:top] || 40)

    CheckRender.render_result(result, opts[:format], &CheckRender.render_candidates_text/1)
  end

  defp plugin_opts(opts), do: Keyword.take(opts, [:plugins])

  defp load_candidates_project(opts, positional) do
    path = opts[:path] || List.first(positional)

    cond do
      opts[:project] ->
        opts[:project]

      path ->
        Project.load([paths: [path], quiet: opts[:format] == "json"] ++ plugin_opts(opts))

      true ->
        Project.load([quiet: opts[:format] == "json"] ++ plugin_opts(opts))
    end
  end
end
