defmodule Reach.CLI.Project do
  @moduledoc false

  alias Reach.Check.AnalysisScope
  alias Reach.Project, as: ReachProject
  alias Reach.Project.Query

  @analysis_scope_key {__MODULE__, :analysis_scope}
  @display_root_key {__MODULE__, :display_root}

  def analysis_scope, do: Process.get(@analysis_scope_key)
  def display_root, do: Process.get(@display_root_key)

  def reset_analysis_scope, do: Process.delete(@analysis_scope_key)

  def load(opts \\ []) do
    Query.reset_cache()
    quiet? = Keyword.get(opts, :quiet, false)
    show_scope? = Keyword.get(opts, :show_scope, false)
    compile(quiet?)

    case Keyword.get(opts, :paths) do
      nil ->
        set_display_root(File.cwd!())
        %{roots: roots, files: files} = ReachProject.mix_source_files(project_opts(opts))
        register_analysis_scope(:mix, roots, files, Mix.env())
        render_analysis_start(quiet?, show_scope?, :project, files)
        ReachProject.from_sources(files, project_opts(opts))

      paths ->
        set_display_root(display_root_for_paths(paths))
        roots = List.wrap(paths)
        files = expand_paths(paths)
        register_analysis_scope(:paths, roots, files, nil)
        render_analysis_start(quiet?, show_scope?, :files, files)
        ReachProject.from_sources(files, project_opts(opts))
    end
  end

  def register_analysis_scope(source, roots, files, mix_env \\ nil) do
    scope =
      AnalysisScope.new(
        source: source,
        source_roots: roots,
        file_count: length(files),
        mix_env: mix_env
      )

    Process.put(@analysis_scope_key, scope)
  end

  defp render_analysis_start(true, _show_scope?, _kind, _files), do: :ok

  defp render_analysis_start(false, show_scope?, kind, files) do
    case kind do
      :project -> Mix.shell().info("Analyzing project...")
      :files -> Mix.shell().info("Analyzing #{length(files)} file(s)...")
    end

    if show_scope? do
      Mix.shell().info("Analysis scope: #{AnalysisScope.describe(analysis_scope())}")
    end
  end

  defp set_display_root(root), do: Process.put(@display_root_key, Path.expand(root))

  defp display_root_for_paths(paths) do
    paths
    |> List.wrap()
    |> Enum.map(&root_candidate/1)
    |> common_path()
  end

  defp root_candidate(path) do
    expanded = Path.expand(path)

    cond do
      String.contains?(path, "*") ->
        path |> Path.dirname() |> Path.expand()

      File.dir?(expanded) and Path.basename(expanded) in ["lib", "src"] ->
        Path.dirname(expanded)

      File.dir?(expanded) ->
        expanded

      true ->
        expanded |> Path.dirname() |> source_root_from_file()
    end
  end

  defp source_root_from_file(dir) do
    parts = Path.split(dir)

    parts
    |> Enum.with_index()
    |> Enum.filter(fn {part, _index} -> part in ["lib", "src"] end)
    |> List.last()
    |> case do
      {_source_dir, 0} -> dir
      {_source_dir, index} -> parts |> Enum.take(index) |> Path.join()
      nil -> dir
    end
  end

  defp common_path([]), do: File.cwd!()
  defp common_path([path]), do: path

  defp common_path(paths) do
    split_paths = Enum.map(paths, &List.to_tuple(Path.split(&1)))
    min_length = split_paths |> Enum.min_by(&tuple_size/1) |> tuple_size()

    common_parts =
      0..(min_length - 1)
      |> Enum.reduce_while([], fn index, acc ->
        parts = Enum.map(split_paths, &elem(&1, index))

        if Enum.uniq(parts) |> length() == 1,
          do: {:cont, [List.first(parts) | acc]},
          else: {:halt, acc}
      end)
      |> Enum.reverse()

    case common_parts do
      [] -> File.cwd!()
      parts -> Path.join(parts)
    end
  end

  defp expand_paths(paths) do
    paths
    |> List.wrap()
    |> Enum.flat_map(&expand_path/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp expand_path(path) do
    cond do
      File.dir?(path) -> glob_dir(path)
      String.contains?(path, "*") -> Path.wildcard(path)
      true -> [path]
    end
  end

  defp glob_dir(path) do
    for ext <- [".ex", ".erl"],
        file <- Path.wildcard(Path.join(path, "**/*#{ext}")),
        do: file
  end

  defp project_opts(opts),
    do: Keyword.take(opts, [:plugins, :source_only, :retain_module_sdgs])

  def compile(quiet? \\ false)

  def compile(true) do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Quiet)

    try do
      Mix.Task.run("compile", ["--no-warnings-as-errors"])
    after
      Mix.shell(shell)
    end
  end

  def compile(false), do: Mix.Task.run("compile", ["--no-warnings-as-errors"])
end
