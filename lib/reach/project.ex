defmodule Reach.Project do
  @moduledoc """
  Multi-file project analysis.

  Builds graphs for all source files in a project, links cross-module
  call edges, and applies external function summaries for dependencies.

  ## Examples

      # Analyze a full Mix project
      project = Reach.Project.from_mix_project()

      # Analyze specific paths
      project = Reach.Project.from_glob("lib/**/*.ex")

      # Query across the whole project
      Reach.Project.taint_analysis(project,
        sources: [type: :call, function: :params],
        sinks: [type: :call, module: System, function: :cmd]
      )
  """

  alias Reach.{DependencySummary, Frontend, IR, Plugin}
  alias Reach.IR.Counter

  import Reach.IR.Helpers, only: [module_from_path: 1]

  @type t :: %__MODULE__{
          modules: %{module() => map()},
          graph: Graph.t(),
          nodes: %{IR.Node.id() => IR.Node.t()},
          call_graph: Graph.t(),
          summaries: %{{module(), atom(), non_neg_integer()} => map()},
          plugins: [module()]
        }

  @enforce_keys [:modules, :graph, :nodes, :call_graph]
  defstruct [:modules, :graph, :nodes, :call_graph, summaries: %{}, plugins: []]

  @doc """
  Builds a project graph from source file paths.
  """
  @spec from_sources([Path.t()], keyword()) :: t()
  def from_sources(paths, opts \\ []) do
    module_sdgs =
      paths
      |> parse_files(opts)
      |> build_module_sdgs(opts)

    merge_project(module_sdgs, opts)
  end

  @doc """
  Builds a project graph from a glob pattern.
  """
  @spec from_glob(String.t(), keyword()) :: t()
  def from_glob(pattern, opts \\ []) do
    pattern
    |> Path.wildcard()
    |> Enum.sort()
    |> from_sources(opts)
  end

  @doc """
  Builds a project graph from the current Mix project.

  Uses `Mix.Project.config()` to discover source paths via `:elixirc_paths`
  and `:erlc_paths`. Umbrella children are included automatically.
  """
  @spec from_mix_project(keyword()) :: t()
  def from_mix_project(opts \\ []) do
    plugins = Reach.Plugin.resolve(opts)

    source_roots()
    |> Enum.flat_map(&source_files(&1, plugins))
    |> Enum.uniq()
    |> Enum.sort()
    |> from_sources(opts)
  end

  defp source_roots do
    config = Mix.Project.config()
    elixirc = config[:elixirc_paths] || ["lib"]
    erlc = config[:erlc_paths] || ["src"]

    case Mix.Project.apps_paths(config) do
      nil ->
        [{elixirc, erlc} | discovered_child_roots(elixirc, erlc)]

      apps_paths ->
        children =
          Enum.map(apps_paths, fn {_app, app_path} ->
            child_config = app_mix_config(app_path)
            child_elixirc = child_config[:elixirc_paths] || ["lib"]
            child_erlc = child_config[:erlc_paths] || ["src"]

            {
              Enum.map(child_elixirc, &Path.join(app_path, &1)),
              Enum.map(child_erlc, &Path.join(app_path, &1))
            }
          end)

        [{elixirc, erlc} | children]
    end
  end

  defp discovered_child_roots(root_elixirc, root_erlc) do
    root_set = MapSet.new(root_elixirc ++ root_erlc)

    deps_path = Mix.Project.config()[:deps_path] || "deps"
    build_path = Mix.Project.build_path()

    ["apps/*/lib", "apps/*/src", "*/lib", "*/src"]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.reject(fn path ->
      Path.dirname(path) in root_set or
        String.starts_with?(path, deps_path <> "/") or
        String.starts_with?(path, build_path <> "/")
    end)
    |> Enum.group_by(&Path.dirname/1)
    |> Enum.map(fn {_parent, dirs} ->
      elixirc = Enum.filter(dirs, &String.ends_with?(&1, "/lib"))
      erlc = Enum.filter(dirs, &String.ends_with?(&1, "/src"))
      {elixirc, erlc}
    end)
  end

  defp app_mix_config(app_path) do
    mix_file = Path.join(app_path, "mix.exs")

    if File.regular?(mix_file) do
      [{module, _}] = Code.compile_file(mix_file)
      module.project()
    else
      []
    end
  rescue
    _ -> []
  end

  defp source_files({elixirc_paths, erlc_paths}, plugins) do
    plugin_extensions = Reach.Plugin.source_extensions(plugins)
    elixir_files = glob_extensions(elixirc_paths, [".ex"] ++ plugin_extensions)
    erlang_files = glob_extensions(erlc_paths, [".erl"])
    elixir_files ++ erlang_files
  end

  defp glob_extensions(paths, extensions) do
    for path <- paths,
        ext <- extensions,
        file <- Path.wildcard(Path.join(path, "**/*#{ext}")),
        do: file
  end

  @doc """
  Computes a function summary for a compiled dependency module.

  Returns a map of `{module, function, arity} => %{param_index => flows_to_return?}`.
  These summaries can be passed as the `:summaries` option to `from_sources/2`.
  """
  @spec summarize_dependency(module()) :: %{{module(), atom(), non_neg_integer()} => map()}
  def summarize_dependency(module), do: DependencySummary.summarize(module)

  @doc """
  Runs taint analysis across the entire project.

  Same interface as `Reach.taint_analysis/2` but searches all modules.
  """
  @spec taint_analysis(t(), keyword()) :: [map()]
  def taint_analysis(%__MODULE__{nodes: nodes} = project, opts) do
    source_filter = Keyword.fetch!(opts, :sources)
    sink_filter = Keyword.fetch!(opts, :sinks)
    sanitizer_filter = Keyword.get(opts, :sanitizers)

    all = Map.values(nodes)
    sources = filter_by(all, source_filter)
    sinks = filter_by(all, sink_filter)

    for source <- sources,
        sink <- sinks,
        data_flows_in_graph?(project.graph, source.id, sink.id) do
      path = chop_in_graph(project.graph, source.id, sink.id)

      sanitized =
        sanitizer_filter != nil and
          path_matches_filter?(path, nodes, sanitizer_filter)

      %{source: source, sink: sink, path: path, sanitized: sanitized}
    end
  end

  defp path_matches_filter?(path, nodes, filter) do
    Enum.any?(path, fn id ->
      case Map.get(nodes, id) do
        nil -> false
        node -> matches_filter?(node, filter)
      end
    end)
  end

  defp data_flows_in_graph?(graph, source_id, sink_id) do
    if Graph.has_vertex?(graph, source_id) do
      sink_id in Graph.reachable(graph, [source_id])
    else
      false
    end
  end

  defp chop_in_graph(graph, source_id, sink_id) do
    fwd = graph |> Graph.reachable([source_id]) |> MapSet.new()

    bwd =
      if Graph.has_vertex?(graph, sink_id),
        do: graph |> Graph.reaching([sink_id]) |> MapSet.new(),
        else: MapSet.new()

    fwd
    |> MapSet.intersection(bwd)
    |> MapSet.delete(source_id)
    |> MapSet.delete(sink_id)
    |> MapSet.to_list()
  end

  defp filter_by(nodes, filter) when is_list(filter) do
    Enum.filter(nodes, fn node -> Enum.all?(filter, &matches_kv?(node, &1)) end)
  end

  defp filter_by(nodes, filter) when is_function(filter), do: Enum.filter(nodes, filter)

  defp matches_kv?(node, {:type, type}), do: node.type == type
  defp matches_kv?(node, {:module, mod}), do: node.meta[:module] == mod
  defp matches_kv?(node, {:function, fun}), do: node.meta[:function] == fun
  defp matches_kv?(node, {:arity, arity}), do: node.meta[:arity] == arity
  defp matches_kv?(_node, _unknown_filter), do: false

  defp matches_filter?(node, filter) when is_list(filter),
    do: Enum.all?(filter, &matches_kv?(node, &1))

  defp matches_filter?(node, filter) when is_function(filter), do: filter.(node)

  # --- Private ---

  defp parse_files(paths, opts) do
    counter = Keyword.get_lazy(opts, :counter, &Counter.new/0)

    paths
    |> Task.async_stream(&parse_path(&1, counter, opts),
      max_concurrency: System.schedulers_online(),
      ordered: false
    )
    |> Enum.flat_map(fn
      {:ok, nil} -> []
      {:ok, result} -> [result]
    end)
  end

  defp parse_path(path, counter, opts) do
    module_name = module_from_path(path)
    parse_opts = Keyword.merge(opts, file: path, counter: counter)

    case parse_source_file(path, parse_opts) do
      {:ok, ir_nodes} ->
        {module_name || extract_module_name(ir_nodes), path, ir_nodes}

      {:error, _} ->
        nil
    end
  end

  defp parse_source_file(path, opts) do
    plugins = Plugin.resolve(opts)
    ext = Path.extname(path)

    if ext in Plugin.source_extensions(plugins) do
      Plugin.parse_file(plugins, path, opts)
    else
      Frontend.parse_file(path, opts)
    end
  end

  defp build_module_sdgs(parsed_modules, opts) do
    Reach.Effects.ensure_cache()
    summaries = Keyword.get(opts, :summaries, %{})

    parsed_modules
    |> Task.async_stream(
      fn {module_name, _path, ir_nodes} ->
        sdg =
          Reach.SystemDependence.build(ir_nodes,
            module: module_name,
            summaries: summaries
          )

        {module_name, sdg}
      end,
      max_concurrency: System.schedulers_online(),
      ordered: false
    )
    |> Map.new(fn {:ok, result} -> result end)
  end

  defp merge_project(module_sdgs, opts) do
    summaries = Keyword.get(opts, :summaries, %{})

    # Collect all function defs across modules for cross-module resolution
    external_sdgs = build_external_sdg_map(module_sdgs)

    # Rebuild each module's SDG with cross-module resolution
    module_sdgs =
      Map.new(module_sdgs, fn {mod, sdg} ->
        all_nodes = Map.values(sdg.nodes)
        func_defs = Reach.CallGraph.collect_function_defs(all_nodes, mod)

        # Re-add call edges with cross-module awareness
        graph =
          Reach.SystemDependence.add_call_edges_with_externals(
            sdg.graph,
            all_nodes,
            func_defs,
            external_sdgs: external_sdgs,
            summaries: summaries
          )

        {mod, %{sdg | graph: graph}}
      end)

    sdg_list = Map.values(module_sdgs)

    merged_graph =
      sdg_list
      |> Enum.map(& &1.graph)
      |> Reach.Graph.merge()

    merged_nodes =
      Enum.reduce(sdg_list, %{}, fn sdg, acc -> Map.merge(acc, sdg.nodes) end)

    merged_call_graph =
      sdg_list
      |> Enum.map(& &1.call_graph)
      |> Reach.Graph.merge()

    # Run project-level plugins
    plugins = Reach.Plugin.resolve(opts)
    all_project_nodes = Map.values(merged_nodes)
    plugin_edges = Reach.Plugin.run_analyze_project(plugins, module_sdgs, all_project_nodes, opts)

    merged_graph =
      Enum.reduce(plugin_edges, merged_graph, fn {v1, v2, label}, g ->
        Graph.add_edge(g, v1, v2, label: label)
      end)

    Reach.Effects.infer_local_effects(merged_nodes)

    %__MODULE__{
      modules: module_sdgs,
      graph: merged_graph,
      nodes: merged_nodes,
      call_graph: merged_call_graph,
      summaries: summaries,
      plugins: plugins
    }
  end

  defp build_external_sdg_map(module_sdgs) do
    for {_mod, sdg} <- module_sdgs,
        {func_id, pdg} <- sdg.function_pdgs,
        func_def = find_func_def(pdg),
        func_def != nil,
        into: %{} do
      {func_id, %{func_def: func_def, pdg: pdg}}
    end
  end

  defp find_func_def(pdg) do
    Map.get(pdg, :func_def) ||
      Enum.find_value(pdg.nodes, fn {_id, node} ->
        if node.type == :function_def, do: node
      end)
  end

  defp extract_module_name(ir_nodes) do
    Enum.find_value(ir_nodes, fn
      %{type: :module_def, meta: %{name: name}} -> name
      _ -> nil
    end)
  end
end
