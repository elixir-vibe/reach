defmodule Reach.Smell.PatternRunner do
  @moduledoc false

  alias ExAST.Patcher
  alias Reach.Smell.Finding
  alias Reach.Smell.PatternConfig
  alias Reach.Smell.Source

  def run(project, checks, files \\ nil) do
    check_configs =
      Enum.map(checks, fn check ->
        {check, PatternConfig.normalize(check, check.__reach_pattern_check__())}
      end)

    files = files || Source.module_files(project)
    Enum.flat_map(files, &scan_file(&1, check_configs))
  end

  defp scan_file(file, check_configs) do
    if File.regular?(file) do
      active_configs = Enum.reject(check_configs, &same_source_file?(&1, file))
      source = lazy_source(file, active_configs)
      zipper = Source.cached_zipper(file)

      find_pattern_smells(zipper, source, file, active_configs) ++
        find_query_smells(zipper, source, file, active_configs)
    else
      []
    end
  rescue
    _error in [ArgumentError, File.Error, MatchError, Protocol.UndefinedError] -> []
  end

  defp same_source_file?({_module, %{source: source}}, file) do
    Path.expand(source) == Path.expand(file)
  end

  defp lazy_source(file, check_configs) do
    if Enum.any?(check_configs, fn {_module, %{patterns: patterns, queries: queries}} ->
         Enum.any?(patterns, &PatternConfig.prefiltered?/1) or
           Enum.any?(queries, &PatternConfig.prefiltered?/1)
       end) do
      File.read!(file)
    end
  end

  defp find_pattern_smells(zipper, source, file, check_configs) do
    {named, meta} = pattern_maps(check_configs, source)

    if map_size(named) == 0 do
      []
    else
      zipper
      |> Patcher.find_many(named)
      |> Enum.map(fn match ->
        {kind, message} = Map.fetch!(meta, match.pattern)
        line = (match.range && match.range.start[:line]) || 0

        Finding.new(
          kind: kind,
          message: message,
          location: "#{file}:#{line}",
          source_range: match.range
        )
      end)
    end
  end

  defp pattern_maps(check_configs, source) do
    check_configs
    |> Stream.with_index()
    |> Enum.reduce({%{}, %{}}, fn {{_module, %{patterns: patterns}}, module_idx}, acc ->
      add_patterns(patterns, module_idx, source, acc)
    end)
  end

  defp add_patterns(patterns, module_idx, source, acc) do
    patterns
    |> Stream.with_index()
    |> Enum.reduce(acc, fn pattern_entry, acc ->
      add_pattern(pattern_entry, module_idx, source, acc)
    end)
  end

  defp add_pattern(
         {{pattern, kind, message, prefilter}, pattern_idx},
         module_idx,
         source,
         {named, meta}
       ) do
    if PatternConfig.source_matches?(source, prefilter) do
      name = :"p#{module_idx}_#{pattern_idx}"
      {Map.put(named, name, pattern), Map.put(meta, name, {kind, message})}
    else
      {named, meta}
    end
  end

  defp find_query_smells(zipper, source, file, check_configs) do
    Enum.flat_map(check_configs, fn {module, %{queries: queries}} ->
      queries
      |> Enum.filter(fn {_fun_name, _kind, _message, prefilter} ->
        PatternConfig.source_matches?(source, prefilter)
      end)
      |> Enum.flat_map(&query_smells(zipper, file, module, &1))
    end)
  end

  defp query_smells(zipper, file, module, {fun_name, kind, message, _prefilter}) do
    zipper
    |> Patcher.find_all(apply(module, fun_name, []))
    |> Enum.map(fn match ->
      line = (match.range && match.range.start[:line]) || 0

      Finding.new(
        kind: kind,
        message: message,
        location: "#{file}:#{line}",
        source_range: match.range
      )
    end)
  end
end
