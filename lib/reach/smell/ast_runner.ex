defmodule Reach.Smell.ASTRunner do
  @moduledoc false

  alias Reach.Smell.Finding
  alias Reach.Smell.PatternConfig
  alias Reach.Smell.Source

  def run(project, checks, files \\ nil) do
    checks
    |> Enum.flat_map(&check_entries/1)
    |> run_entries(project, files)
  end

  defp check_entries(check) do
    if function_exported?(check, :__reach_ast_smells__, 0) do
      Enum.map(check.__reach_ast_smells__(), &{check, normalize_entry(&1)})
    else
      []
    end
  end

  defp normalize_entry({callback, kind, message, prefilter}),
    do: {callback, kind, message, prefilter, :review_only}

  defp normalize_entry({callback, kind, message, prefilter, remediation_safety}),
    do: {callback, kind, message, prefilter, remediation_safety}

  defp run_entries([], _project, _files), do: []

  defp run_entries(entries, project, files) do
    files = files || Source.module_files(project)
    Enum.flat_map(files, &scan_file(&1, entries))
  end

  defp scan_file(file, entries) do
    if File.regular?(file) do
      source = File.read!(file)
      active_entries = Enum.filter(entries, &entry_matches_source?(source, &1))

      if active_entries == [] do
        []
      else
        file
        |> Source.cached_ast()
        |> scan_ast(file, active_entries)
      end
    else
      []
    end
  rescue
    _error in [ArgumentError, File.Error, MatchError] -> []
  end

  defp entry_matches_source?(
         source,
         {_check, {_callback, _kind, _message, prefilter, _remediation_safety}}
       ) do
    PatternConfig.source_matches?(source, prefilter)
  end

  defp scan_ast(ast, file, entries) do
    {_ast, findings} =
      Macro.prewalk(ast, [], fn node, findings ->
        {node, node_findings(node, file, entries) ++ findings}
      end)

    Enum.reverse(findings)
  end

  defp node_findings(node, file, entries) do
    Enum.flat_map(entries, fn
      {check, {callback, kind, message, _prefilter, remediation_safety}} ->
        check.__reach_ast_smell_match__(callback, node)
        |> finding_result(file, kind, message, remediation_safety)
    end)
  end

  defp finding_result(nil, _file, _kind, _message, _remediation_safety), do: []
  defp finding_result(false, _file, _kind, _message, _remediation_safety), do: []
  defp finding_result(:error, _file, _kind, _message, _remediation_safety), do: []

  defp finding_result(:ok, file, kind, message, remediation_safety),
    do: [finding(file, [], kind, message, remediation_safety)]

  defp finding_result({:ok, meta}, file, kind, message, remediation_safety),
    do: [finding(file, meta, kind, message, remediation_safety)]

  defp finding_result({:ok, meta, message}, file, kind, _message, remediation_safety),
    do: [finding(file, meta, kind, message, remediation_safety)]

  defp finding_result({:ok, meta, kind, message}, file, _kind, _message, remediation_safety),
    do: [finding(file, meta, kind, message, remediation_safety)]

  defp finding_result(_other, _file, _kind, _message, _remediation_safety), do: []

  defp finding(file, meta, kind, message, remediation_safety) do
    Finding.new(
      kind: kind,
      message: message,
      remediation_safety: remediation_safety,
      location: "#{file}:#{meta[:line] || 0}"
    )
  end
end
