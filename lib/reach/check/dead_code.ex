defmodule Reach.Check.DeadCode do
  @moduledoc """
  Finds dead code — pure expressions whose values are never used.
  """

  alias Reach.Check.DeadCode.Finding

  def collect_files(nil) do
    config = Mix.Project.config()
    elixirc = config[:elixirc_paths] || ["lib"]
    erlc = config[:erlc_paths] || ["src"]

    glob(elixirc, ".ex") ++ glob(erlc, ".erl")
  end

  def collect_files(paths) when is_list(paths) do
    paths
    |> Enum.flat_map(&collect_files/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def collect_files(path) do
    if File.dir?(path), do: glob([path], ".ex") ++ glob([path], ".erl"), else: [path]
  end

  defp glob(paths, ext) do
    Enum.flat_map(paths, &Path.wildcard(Path.join(&1, "**/*#{ext}")))
  end

  def run(files, opts \\ []) do
    plugins = Keyword.get(opts, :plugins, Reach.Plugin.detect())
    declaration_lines = value_discard_safe_lines(files, plugins)

    files
    |> Task.async_stream(&find_in_file(&1, opts),
      max_concurrency: System.schedulers_online(),
      ordered: false,
      timeout: Keyword.get(opts, :task_timeout, 30_000)
    )
    |> Enum.flat_map(fn {:ok, results} -> results end)
    |> Enum.reject(&value_discard_safe?(&1, declaration_lines))
    |> Enum.sort_by(&{&1.file, &1.line})
    |> Enum.uniq_by(&{&1.file, &1.line})
  end

  defp value_discard_safe_lines(files, plugins) do
    files
    |> Enum.flat_map(fn file ->
      case Reach.MacroFact.collect_file(file, plugins: plugins) do
        {:ok, facts} -> facts
        {:error, _reason} -> []
      end
    end)
    |> Enum.filter(&value_discard_safe_fact?/1)
    |> MapSet.new(fn fact -> {fact.source[:file], fact.source[:line]} end)
  end

  defp value_discard_safe?(finding, declaration_lines) do
    MapSet.member?(declaration_lines, {finding.file, finding.line})
  end

  defp value_discard_safe_fact?(%Reach.MacroFact{framework: framework, confidence: :high})
       when not is_nil(framework),
       do: true

  defp value_discard_safe_fact?(_fact), do: false

  defp find_in_file(file, opts) do
    case Reach.file_to_graph(file, opts) do
      {:ok, graph} ->
        graph
        |> Reach.dead_code()
        |> Enum.filter(& &1.source_span)
        |> Enum.map(&finding_from_node(&1, file))

      _ ->
        []
    end
  end

  defp finding_from_node(node, file) do
    Finding.new(
      file: file,
      line: node.source_span.start_line,
      kind: node.type,
      description: describe(node)
    )
  end

  defp describe(node) do
    case node.type do
      :call ->
        mod = node.meta[:module]
        fun = node.meta[:function]
        if mod, do: "#{inspect(mod)}.#{fun} result unused", else: "#{fun} result unused"

      :binary_op ->
        "#{node.meta[:operator]} result unused"

      :unary_op ->
        "#{node.meta[:operator]} result unused"

      :match ->
        match_description(node)

      _ ->
        "#{node.type} unused"
    end
  end

  defp match_description(node) do
    case node.children do
      [%{type: :var, meta: %{name: name}}, %{type: :call} = rhs] ->
        mod = if rhs.meta[:module], do: inspect(rhs.meta[:module]) <> ".", else: ""
        "#{name} = #{mod}#{rhs.meta[:function]} is unused"

      [%{type: :var, meta: %{name: name}} | _] ->
        "#{name} = ... is unused"

      _ ->
        "match result unused"
    end
  end
end
