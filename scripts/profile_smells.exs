#!/usr/bin/env elixir

Mix.Task.run("app.start")

defmodule Reach.Smell.ProfileScript do
  alias ExAST.Patcher
  alias Reach.Config
  alias Reach.Smell.PatternConfig
  alias Reach.Smell.Source

  def main(argv) do
    {opts, _argv, invalid} =
      OptionParser.parse(argv,
        strict: [
          checks: :boolean,
          patterns: :boolean,
          queries: :boolean,
          repo: :string,
          glob: :keep,
          limit: :integer,
          help: :boolean
        ],
        aliases: [c: :checks, p: :patterns, q: :queries, r: :repo, g: :glob, l: :limit, h: :help]
      )

    if opts[:help] == true or invalid != [] do
      print_help(invalid)
    else
      profile(opts)
    end
  end

  defp print_help(invalid) do
    IO.puts("""
    Usage: mix run scripts/profile_smells.exs [options]

    Profiles smell checks against the current project or a source repo.

    Options:
      --checks, -c     show per-check timings (default when no detail flags are passed)
      --patterns, -p   show per-pattern-check timings
      --queries, -q    show per-query timings inside ExAST pattern checks
      --repo PATH, -r  profile sources under PATH instead of current project
      --glob GLOB, -g  source glob relative to --repo; can be repeated
                      defaults to lib/**/*.ex and apps/*/lib/**/*.ex
      --limit N, -l N  limit rows per table
      --help, -h       show this help
    """)

    System.halt(if invalid == [], do: 0, else: 1)
  end

  defp profile(opts) do
    show_checks? = opts[:checks] == true || (opts[:patterns] != true && opts[:queries] != true)
    show_patterns? = opts[:patterns] == true
    show_queries? = opts[:queries] == true

    {project, config} = load_project(opts)
    checks = Reach.Smell.Registry.checks(project, config)
    {pattern_checks, semantic_checks} = Enum.split_with(checks, &pattern_check?/1)
    files = source_files(project)

    if opts[:repo], do: IO.puts("Repo: #{opts[:repo]}")
    IO.puts("Project nodes: #{map_size(project.nodes)}")
    IO.puts("Source files: #{length(files)}")
    IO.puts("Pattern checks: #{length(pattern_checks)}")
    IO.puts("Semantic checks: #{length(semantic_checks)}")
    IO.puts("")

    {pattern_us, pattern_findings} =
      :timer.tc(fn -> Reach.Smell.SourceRunner.run(project, pattern_checks) end)

    {semantic_us, semantic_findings} =
      :timer.tc(fn -> Enum.flat_map(semantic_checks, &run_check(&1, project, config)) end)

    table("Totals", [
      {"pattern", ms(pattern_us), length(pattern_findings)},
      {"semantic", ms(semantic_us), length(semantic_findings)},
      {"all", ms(pattern_us + semantic_us), length(pattern_findings) + length(semantic_findings)}
    ])

    limit = opts[:limit]

    if show_checks?, do: profile_checks(project, config, pattern_checks, semantic_checks, limit)
    if show_patterns?, do: profile_patterns(files, pattern_checks, limit)
    if show_queries?, do: profile_queries(files, pattern_checks, limit)
  end

  defp profile_checks(project, config, pattern_checks, semantic_checks, limit) do
    pattern_rows =
      Enum.map(pattern_checks, fn check ->
        {us, findings} = :timer.tc(fn -> Reach.Smell.SourceRunner.run(project, [check]) end)
        {inspect(check), ms(us), length(findings)}
      end)

    semantic_rows =
      Enum.map(semantic_checks, fn check ->
        {us, findings} = :timer.tc(fn -> run_check(check, project, config) end)
        {inspect(check), ms(us), length(findings)}
      end)

    table("Pattern checks", Enum.sort_by(pattern_rows, &elem(&1, 1), :desc), limit)
    table("Semantic checks", Enum.sort_by(semantic_rows, &elem(&1, 1), :desc), limit)
  end

  defp profile_patterns(files, pattern_checks, limit) do
    rows = Enum.flat_map(pattern_checks, &profile_pattern_check(files, &1))
    table("ExAST pattern groups", Enum.sort_by(rows, &elem(&1, 1), :desc), limit)
  end

  defp profile_queries(files, pattern_checks, limit) do
    rows = Enum.flat_map(pattern_checks, &profile_check_queries(files, &1))
    table("ExAST selector queries", Enum.sort_by(rows, &elem(&1, 1), :desc), limit)
  end

  defp load_project(opts) do
    config = Config.read() |> Config.normalize()

    case opts[:repo] do
      nil ->
        {Reach.CLI.Project.load(quiet: true), config}

      repo ->
        paths = source_paths(repo, opts[:glob] || default_globs())
        plugins = [Reach.Plugins.Phoenix, Reach.Plugins.Ecto, Reach.Plugins.Oban]
        {Reach.Project.from_sources(paths, plugins: plugins), config}
    end
  end

  defp default_globs, do: ["lib/**/*.ex", "apps/*/lib/**/*.ex"]

  defp source_paths(repo, globs) do
    repo = Path.expand(repo)

    globs
    |> Enum.flat_map(fn glob -> Path.wildcard(Path.join(repo, glob)) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp pattern_check?(check) do
    Code.ensure_loaded?(check) and function_exported?(check, :__reach_pattern_check__, 0)
  end

  defp run_check(check, project, config) do
    if function_exported?(check, :run, 2),
      do: check.run(project, config),
      else: check.run(project)
  end

  defp source_files(project) do
    project.nodes
    |> Enum.flat_map(fn
      {_id, %{type: :module_def, source_span: %{file: file}}} when is_binary(file) -> [file]
      _entry -> []
    end)
    |> Enum.uniq()
    |> Enum.filter(&File.regular?/1)
  end

  defp profile_pattern_check(files, check) do
    %{patterns: patterns} = config = check.__reach_pattern_check__()
    %{patterns: normalized} = PatternConfig.normalize(check, config)
    active_files = matching_files(files, normalized)

    {us, matches} =
      :timer.tc(fn ->
        Enum.reduce(active_files, 0, fn file, count ->
          zipper = Source.cached_zipper(file)
          {named, _meta} = pattern_maps(normalized, File.read!(file))
          count + if(map_size(named) == 0, do: 0, else: length(Patcher.find_many(zipper, named)))
        end)
      end)

    [
      {"#{inspect(check)} patterns=#{length(patterns)} files=#{length(active_files)}", ms(us),
       matches}
    ]
  end

  defp profile_check_queries(files, check) do
    %{queries: queries} = check.__reach_pattern_check__()

    Enum.map(queries, fn query ->
      {fun_name, _kind, message, prefilter, _safety} =
        PatternConfig.normalize_query(check, query)

      selector = apply(check, fun_name, [])
      active_files = Enum.filter(files, &PatternConfig.source_matches?(File.read!(&1), prefilter))

      {us, matches} =
        :timer.tc(fn ->
          Enum.reduce(active_files, 0, fn file, count ->
            count + length(Patcher.find_all(Source.cached_zipper(file), selector))
          end)
        end)

      label =
        "#{inspect(check)} #{fun_name} files=#{length(active_files)} #{String.slice(message, 0, 72)}"

      {label, ms(us), matches}
    end)
  end

  defp matching_files(files, patterns) do
    Enum.filter(files, fn file ->
      source = File.read!(file)

      Enum.any?(patterns, fn {_pattern, _kind, _message, prefilter, _safety} ->
        PatternConfig.source_matches?(source, prefilter)
      end)
    end)
  end

  defp pattern_maps(patterns, source) do
    patterns
    |> Stream.with_index()
    |> Enum.reduce(
      {%{}, %{}},
      fn {{pattern, kind, message, prefilter, _safety}, idx}, {named, meta} ->
        if PatternConfig.source_matches?(source, prefilter) do
          name = :"p#{idx}"
          {Map.put(named, name, pattern), Map.put(meta, name, {kind, message})}
        else
          {named, meta}
        end
      end
    )
  end

  defp ms(us), do: System.convert_time_unit(us, :microsecond, :millisecond)

  defp table(title, rows), do: table(title, rows, nil)

  defp table(title, rows, limit) do
    IO.puts(title)
    IO.puts(String.duplicate("-", String.length(title)))

    if rows == [] do
      IO.puts("(none)\n")
    else
      rows = limit_rows(rows, limit)

      label_width =
        rows |> Enum.map(fn {label, _time, _count} -> String.length(label) end) |> Enum.max()

      for {label, time, count} <- rows do
        IO.puts(
          String.pad_trailing(label, label_width) <>
            "  #{String.pad_leading(to_string(time), 6)} ms  findings=#{count}"
        )
      end

      IO.puts("")
    end
  end

  defp limit_rows(rows, limit) when is_integer(limit) and limit > 0, do: Enum.take(rows, limit)
  defp limit_rows(rows, _limit), do: rows
end

Reach.Smell.ProfileScript.main(System.argv())
