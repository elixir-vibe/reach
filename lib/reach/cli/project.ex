defmodule Reach.CLI.Project do
  @moduledoc false

  alias Reach.Project.Query

  @display_root_key {__MODULE__, :display_root}

  def display_root, do: Process.get(@display_root_key)

  def load(opts \\ []) do
    Query.reset_cache()
    quiet? = Keyword.get(opts, :quiet, false)
    compile(quiet?)

    case Keyword.get(opts, :paths) do
      nil ->
        set_display_root(File.cwd!())
        unless quiet?, do: Mix.shell().info("Analyzing project...")
        Reach.Project.from_mix_project(project_opts(opts))

      paths ->
        set_display_root(display_root_for_paths(paths))
        paths = expand_paths(paths)
        unless quiet?, do: Mix.shell().info("Analyzing #{length(paths)} file(s)...")
        Reach.Project.from_sources(paths, project_opts(opts))
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
