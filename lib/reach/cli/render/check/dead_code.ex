defmodule Reach.CLI.Render.Check.DeadCode do
  @moduledoc false

  alias Reach.CLI.Format
  alias Reach.CLI.Text

  def render(findings, "json", command, analysis) do
    Format.render(%{findings: findings, analysis: analysis}, command,
      format: "json",
      pretty: true
    )
  end

  def render(findings, "oneline", _command, _analysis) do
    Enum.each(findings, fn finding ->
      IO.puts(
        "#{Format.faint("#{finding.file}:#{finding.line}")}: #{Format.yellow(to_string(finding.kind))}: #{finding.description}"
      )
    end)
  end

  def render([], _format, _command, _analysis) do
    Text.section("Dead Code", [Text.empty()])
  end

  def render(findings, _format, _command, _analysis) do
    Text.section("Dead Code", dead_code_lines(findings))
  end

  defp dead_code_lines(findings) do
    findings
    |> Enum.group_by(& &1.file)
    |> Enum.sort_by(fn {file, _} -> file end)
    |> Enum.flat_map(fn {file, file_findings} ->
      [Text.subsection(Format.faint(file))] ++
        Enum.map(file_findings, fn finding ->
          Text.line("line #{Format.yellow(to_string(finding.line))}: #{finding.description}")
        end)
    end)
    |> Kernel.++([Text.blank(), Text.summary("#{Format.count(length(findings))} finding(s)")])
  end
end
