defmodule Reach.Plugin do
  @moduledoc """
  Behaviour for library-specific analysis plugins.

  Plugins extend Reach in three ways:

  1. **Graph edges** — `analyze/2` and `analyze_project/3` add domain-specific
     edges to the dependence graph (framework dispatch, message routing, etc.)

  2. **Effect classification** — `classify_effect/1` teaches the effect
     classifier about framework-specific calls (Ecto queries are pure,
     Repo writes are `:write`, etc.)

  3. **Source frontends** — optional `source_extensions/0` and `parse_file/2`
     callbacks let plugins own language frontends for optional ecosystems.

  4. **Embedded IR** — `analyze_embedded/2` extracts code from string
     literals (e.g. JS inside QuickBEAM.eval) and returns additional IR
     nodes plus cross-language edges.

  5. **Framework presentation/patterns** — optional callbacks provide
     framework-specific trace presets, behaviour labels, and visualization
     edge filtering.

  ## Implementing a plugin

      defmodule MyPlugin do
        @behaviour Reach.Plugin

        @impl true
        def analyze(all_nodes, _opts), do: []

        @impl true
        def classify_effect(%Reach.IR.Node{type: :call, meta: %{function: :my_pure_fn}}), do: :pure
        def classify_effect(_), do: nil
      end

  ## Built-in plugins

  Plugins for Phoenix, Ecto, Oban, GenStage, Jido, and OpenTelemetry
  are included and auto-detected at runtime. Override with the
  `:plugins` option:

      Reach.Project.from_mix_project(plugins: [Reach.Plugins.Ecto])

  Disable auto-detection:

      Reach.string_to_graph!(source, plugins: [])
  """

  alias Reach.IR.Node

  @type edge_spec :: {Node.id(), Node.id(), term()}
  @type embedded_result :: {[Node.t()], [edge_spec()]}

  @doc """
  Analyzes IR nodes from a single module and returns edges to add.
  """
  @callback analyze(all_nodes :: [Node.t()], opts :: keyword()) :: [edge_spec()]

  @doc """
  Analyzes IR nodes across all modules in a project.

  Only needed for cross-module patterns like router→controller
  dispatch or job enqueue→perform flow.
  """
  @callback analyze_project(
              modules :: %{module() => map()},
              all_nodes :: [Node.t()],
              opts :: keyword()
            ) :: [edge_spec()]

  @doc """
  Classifies the effect of a call node.

  Return an effect atom (`:pure`, `:read`, `:write`, `:io`, `:send`,
  `:exception`) or `nil` to defer to the next classifier.
  """
  @callback classify_effect(node :: Node.t()) :: atom() | nil

  @doc """
  Extracts embedded code from IR nodes (e.g. JS strings passed to
  QuickBEAM.eval) and returns additional IR nodes plus edges
  connecting them to the host graph.
  """
  @callback analyze_embedded(all_nodes :: [Node.t()], opts :: keyword()) :: embedded_result()
  @callback source_extensions() :: [String.t()]
  @callback source_language(extension :: String.t()) :: atom() | nil
  @callback parse_file(path :: Path.t(), opts :: keyword()) ::
              {:ok, [Node.t()]} | {:error, term()}

  @callback smell_checks() :: [module()]
  @callback evidence_providers() :: [module()]
  @callback refine_evidence(evidence :: struct() | map(), context :: map()) ::
              struct() | map() | :unchanged
  @callback trace_pattern(pattern :: String.t()) :: (Node.t() -> boolean()) | nil
  @callback behaviour_label(callbacks :: [atom()]) :: String.t() | nil
  @callback ignore_call_edge?(Graph.Edge.t()) :: boolean()

  @optional_callbacks analyze_project: 3,
                      classify_effect: 1,
                      analyze_embedded: 2,
                      source_extensions: 0,
                      source_language: 1,
                      parse_file: 2,
                      smell_checks: 0,
                      evidence_providers: 0,
                      refine_evidence: 2,
                      trace_pattern: 1,
                      behaviour_label: 1,
                      ignore_call_edge?: 1

  @known_plugins [
    {Phoenix.Router, Reach.Plugins.Phoenix},
    {Ecto, Reach.Plugins.Ecto},
    {Ash, Reach.Plugins.Ash},
    {Oban, Reach.Plugins.Oban},
    {GenStage, Reach.Plugins.GenStage},
    {Jido.Action, Reach.Plugins.Jido},
    {OpenTelemetry.Tracer, Reach.Plugins.OpenTelemetry},
    {Jason, Reach.Plugins.Jason},
    {Poison, Reach.Plugins.Poison},
    {QuickBEAM, Reach.Plugins.QuickBEAM}
  ]

  @doc """
  Returns the list of auto-detected plugins based on loaded dependencies.
  """
  def detect do
    for {mod, plugin} <- @known_plugins,
        Code.ensure_loaded?(mod) do
      plugin
    end
  end

  @doc """
  Resolves plugins from options, falling back to auto-detection.
  """
  def resolve(opts) do
    case Keyword.get(opts, :plugins) do
      nil -> detect()
      [] -> []
      list when is_list(list) -> list
    end
  end

  @doc """
  Asks each plugin to classify a call node's effect.

  Returns the first non-nil result, or `nil` if no plugin matches.
  """
  def classify_effect(plugins, node) do
    Enum.find_value(plugins, fn plugin ->
      if exports?(plugin, :classify_effect, 1), do: plugin.classify_effect(node)
    end)
  end

  @doc "Runs module-local analysis hooks for the configured plugins."
  def run_analyze(plugins, all_nodes, opts) do
    Enum.flat_map(plugins, fn plugin ->
      plugin.analyze(all_nodes, opts)
    end)
  end

  @doc "Returns source extensions handled by plugins."
  def source_extensions(plugins) do
    plugins
    |> Enum.flat_map(fn plugin ->
      if exports?(plugin, :source_extensions, 0), do: plugin.source_extensions(), else: []
    end)
    |> Enum.uniq()
  end

  @doc "Returns the source language for an extension handled by a plugin."
  def source_language(plugins, extension) do
    Enum.find_value(plugins, fn plugin ->
      if exports?(plugin, :source_language, 1) and extension in plugin.source_extensions() do
        plugin.source_language(extension)
      end
    end)
  end

  @doc "Parses a source file with the first plugin frontend that accepts its extension."
  def parse_file(plugins, path, opts) do
    ext = Path.extname(path)

    Enum.find_value(plugins, :error, fn plugin ->
      if exports?(plugin, :parse_file, 2) and ext in plugin.source_extensions() do
        plugin.parse_file(path, opts)
      end
    end)
  end

  @doc "Runs embedded-node analysis hooks for plugins that provide them."
  def run_analyze_embedded(plugins, all_nodes, opts) do
    {nodes_acc, edges_acc, _added_chunks} =
      Enum.reduce(plugins, {[], [], []}, fn plugin, {all_nodes_acc, edges_acc, added_chunks} ->
        if exports?(plugin, :analyze_embedded, 2) do
          accumulated = [all_nodes | Enum.reverse(added_chunks)] |> List.flatten()
          {new_nodes, new_edges} = plugin.analyze_embedded(accumulated, opts)
          flat_nodes = List.flatten(new_nodes)

          {[new_nodes | all_nodes_acc], [new_edges | edges_acc], [flat_nodes | added_chunks]}
        else
          {all_nodes_acc, edges_acc, added_chunks}
        end
      end)

    {nodes_acc |> List.flatten() |> Enum.reverse(), edges_acc |> List.flatten() |> Enum.reverse()}
  end

  @doc "Returns smell checks contributed by plugins."
  def smell_checks(plugins) do
    plugins
    |> Enum.flat_map(fn plugin ->
      if exports?(plugin, :smell_checks, 0), do: plugin.smell_checks(), else: []
    end)
    |> Enum.uniq()
  end

  @doc "Returns evidence providers contributed by plugins."
  def evidence_providers(plugins) do
    plugins
    |> Enum.flat_map(fn plugin ->
      if exports?(plugin, :evidence_providers, 0), do: plugin.evidence_providers(), else: []
    end)
    |> Enum.uniq()
  end

  @doc "Lets plugins annotate or adjust evidence facts without owning user-facing policy."
  def refine_evidence(plugins, evidence, context \\ %{}) do
    Enum.reduce(plugins, evidence, fn plugin, evidence ->
      if exports?(plugin, :refine_evidence, 2) do
        apply_evidence_refinement(evidence, plugin.refine_evidence(evidence, context))
      else
        evidence
      end
    end)
  end

  defp apply_evidence_refinement(evidence, :unchanged), do: evidence

  defp apply_evidence_refinement(evidence, updates) when is_map(updates) do
    if same_struct?(evidence, updates) do
      updates
    else
      Map.merge(evidence, updates)
    end
  end

  defp apply_evidence_refinement(evidence, _other), do: evidence

  defp same_struct?(%module{}, %module{}), do: true
  defp same_struct?(_evidence, _updates), do: false

  @doc "Compiles a framework-specific trace pattern, if a plugin recognizes it."
  def trace_pattern(plugins, pattern) do
    Enum.find_value(plugins, fn plugin ->
      if exports?(plugin, :trace_pattern, 1), do: plugin.trace_pattern(pattern)
    end)
  end

  @doc "Infers a framework-specific behaviour label from callback names."
  def behaviour_label(plugins, callbacks) do
    Enum.find_value(plugins, fn plugin ->
      if exports?(plugin, :behaviour_label, 1), do: plugin.behaviour_label(callbacks)
    end)
  end

  @doc "Returns true when a plugin marks a call-graph edge as visualization noise."
  def ignore_call_edge?(plugins, edge) do
    Enum.any?(plugins, fn plugin ->
      exports?(plugin, :ignore_call_edge?, 1) and plugin.ignore_call_edge?(edge)
    end)
  end

  @doc "Runs project-level analysis hooks for plugins that provide them."
  def run_analyze_project(plugins, modules, all_nodes, opts) do
    Enum.flat_map(plugins, fn plugin ->
      if exports?(plugin, :analyze_project, 3),
        do: plugin.analyze_project(modules, all_nodes, opts),
        else: []
    end)
  end

  defp exports?(plugin, function, arity) do
    Code.ensure_loaded?(plugin) and function_exported?(plugin, function, arity)
  end
end
