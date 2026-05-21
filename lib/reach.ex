defmodule Reach do
  @moduledoc """
  Program Dependence Graph for Elixir and Erlang.

  Reach analyzes Elixir and Erlang source code and builds a graph that captures
  **what depends on what**: which expressions produce values consumed
  by others (data dependence), and which expressions control whether
  others execute (control dependence).

  ## Building a graph

      # Elixir (default)
      {:ok, graph} = Reach.string_to_graph(\"""
      def foo(x) do
        y = x + 1
        if y > 10, do: :big, else: :small
      end
      \""")

      # Erlang
      {:ok, graph} = Reach.string_to_graph(source, language: :erlang)

      # Auto-detected from file extension
      {:ok, graph} = Reach.file_to_graph("lib/my_module.ex")
      {:ok, graph} = Reach.file_to_graph("src/my_module.erl")

  ## Querying

      Reach.backward_slice(graph, node_id)
      Reach.forward_slice(graph, node_id)
      Reach.independent?(graph, id_a, id_b)
      Reach.nodes(graph, type: :call, module: Enum)
      Reach.nodes(graph, type: :call, module: Enum, function: :map, arity: 2)
      Reach.data_flows?(graph, source_id, sink_id)

  ## Inspecting nodes

      node = Reach.node(graph, some_id)
      node.type       #=> :call
      node.meta       #=> %{module: Enum, function: :map, arity: 2}
      node.source_span #=> %{file: "lib/foo.ex", start_line: 5, ...}

      Reach.pure?(node)  #=> true
  """

  alias Reach.{Effects, Frontend, IR, Plugin, SystemDependence}
  alias Reach.IR.{Counter, Node}
  import Reach.IR.Helpers, only: [module_from_path: 1]

  @typedoc "A program dependence graph. Built by `string_to_graph/2`, `file_to_graph/2`, etc."
  @type graph :: struct()

  @type node_id :: Node.id()

  # --- Building ---

  @doc """
  Parses a source string and builds a program dependence graph.

  Returns `{:ok, graph}` or `{:error, reason}`.

  ## Options

    * `:language` — `:elixir` (default) or `:erlang`
    * `:file` — filename for source locations (default: `"nofile"`)
    * `:module` — module name for call graph resolution
  """
  @spec string_to_graph(String.t(), keyword()) :: {:ok, graph()} | {:error, term()}
  def string_to_graph(source, opts \\ []) do
    {language, opts} = Keyword.pop(opts, :language, :elixir)

    case parse_string(source, language, opts) do
      {:ok, ir_nodes} -> {:ok, SystemDependence.build(ir_nodes, opts)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Same as `string_to_graph/2` but raises on parse error.
  """
  @spec string_to_graph!(String.t(), keyword()) :: graph()
  def string_to_graph!(source, opts \\ []) do
    case string_to_graph(source, opts) do
      {:ok, graph} -> graph
      {:error, reason} -> raise ArgumentError, "Reach parse error: #{inspect(reason)}"
    end
  end

  @doc """
  Reads a source file and builds a program dependence graph.

  The language is auto-detected from the file extension (`.ex` / `.exs`
  for Elixir, `.erl` / `.hrl` for Erlang), or can be set explicitly
  via the `:language` option.

  Returns `{:ok, graph}` or `{:error, reason}`.
  """
  @spec file_to_graph(Path.t(), keyword()) :: {:ok, graph()} | {:error, term()}
  def file_to_graph(path, opts \\ []) do
    language = Keyword.get(opts, :language) || language_from_extension(path, opts)
    opts = Keyword.put_new(opts, :file, path) |> Keyword.put(:language, language)

    case language do
      :gleam -> parse_file_and_build(&Frontend.Gleam.parse_file/2, path, opts)
      :erlang -> parse_file_and_build(&Frontend.Erlang.parse_file/2, path, opts)
      :elixir -> read_and_build_elixir(path, opts)
      _plugin_language -> parse_plugin_file_and_build(path, opts)
    end
  end

  defp parse_file_and_build(parser, path, opts) do
    case parser.(path, opts) do
      {:ok, nodes} -> {:ok, SystemDependence.build(nodes, opts)}
      {:error, _} = err -> err
    end
  end

  defp read_and_build_elixir(path, opts) do
    case File.read(path) do
      {:ok, source} ->
        opts = Keyword.put_new(opts, :module, module_from_path(path))
        parse_and_build(source, :elixir, opts)

      {:error, reason} ->
        {:error, {:file, reason}}
    end
  end

  @doc """
  Same as `file_to_graph/2` but raises on error.
  """
  @spec file_to_graph!(Path.t(), keyword()) :: graph()
  def file_to_graph!(path, opts \\ []) do
    case file_to_graph(path, opts) do
      {:ok, graph} -> graph
      {:error, reason} -> raise ArgumentError, "Reach error: #{inspect(reason)}"
    end
  end

  @doc """
  Builds a graph from a compiled module (loaded in the VM).

  Analyzes the macro-expanded Erlang abstract forms from the BEAM bytecode.
  This captures code injected by `use`, `defmacro`, and other macros that
  the source-level frontend misses.

  Requires the module to be compiled with debug info (the default).
  """
  @spec module_to_graph(module(), keyword()) :: {:ok, graph()} | {:error, term()}
  def module_to_graph(module, opts \\ []) do
    case Frontend.BEAM.from_module(module, opts) do
      {:ok, nodes} -> {:ok, SystemDependence.build(nodes, opts)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Compiles an Elixir source string and builds a graph from the expanded bytecode.

  Unlike `string_to_graph/2`, this compiles the code first, so macro-expanded
  constructs (try/rescue inside macros, `use` callbacks, etc.) are visible.

  The source must define complete modules.
  """
  @spec compiled_to_graph(String.t() | [{module(), binary()}], keyword()) ::
          {:ok, graph()} | {:error, term()}
  def compiled_to_graph(source_or_modules, opts \\ [])

  def compiled_to_graph(source, opts) when is_binary(source) do
    case Frontend.BEAM.from_compiled_string(source, opts) do
      {:ok, nodes} -> {:ok, SystemDependence.build(nodes, opts)}
      {:error, _} = err -> err
    end
  end

  def compiled_to_graph(compiled, opts) when is_list(compiled) do
    {:ok, nodes} = Frontend.BEAM.from_compiled_modules(compiled, opts)
    {:ok, SystemDependence.build(nodes, opts)}
  end

  def compiled_to_graph(_, _opts), do: {:error, :invalid_input}

  @doc """
  Builds a graph from an already-parsed Elixir AST.

  Useful when you already have the AST (e.g. from Credo or ExDNA)
  and don't want to re-parse source.
  """
  @spec ast_to_graph(Macro.t(), keyword()) :: {:ok, graph()} | {:error, term()}
  def ast_to_graph(ast, opts \\ []) do
    counter = Counter.new()
    file = Keyword.get(opts, :file, "nofile")
    nodes = Frontend.Elixir.translate_ast(ast, counter, file)
    {:ok, SystemDependence.build(List.wrap(nodes), opts)}
  end

  @doc """
  Returns the children of a block in canonical order.

  Independent sibling expressions are sorted by structural hash so
  that reordered-but-equivalent blocks produce the same sequence.
  Dependent expressions preserve their relative order.

  Returns a list of `{node_id, ir_node}` pairs.

  ## Example

      # These two blocks produce the same canonical order:
      #   a = 1; b = 2; c = a + b
      #   b = 2; a = 1; c = a + b
      # Because a=1 and b=2 are independent, they get sorted,
      # while c=a+b stays last (depends on both).
  """
  @spec canonical_order(graph(), Reach.IR.Node.id()) :: [{Reach.IR.Node.id(), Reach.IR.Node.t()}]
  def canonical_order(%SystemDependence{} = graph, block_node_id) do
    block = node(graph, block_node_id)

    case block do
      %{type: type, children: children} when type in [:block, :clause, :function_def] ->
        sort_preserving_deps(graph, children)

      _ ->
        case block do
          %{id: id} = n -> [{id, n}]
          nil -> []
        end
    end
  end

  defp sort_preserving_deps(graph, children) do
    indexed = Enum.with_index(children)

    # Build a dependency map: which children must come before which
    must_precede =
      for {a, i} <- indexed,
          {b, j} <- indexed,
          i < j,
          not independent?(graph, a.id, b.id),
          reduce: MapSet.new() do
        acc -> MapSet.put(acc, {i, j})
      end

    # Topological sort respecting dependencies, breaking ties by structural hash
    sorted_indices = topo_sort_with_hash(indexed, must_precede)

    indexed_tuple = List.to_tuple(indexed)

    Enum.map(sorted_indices, fn i ->
      {node, _} = elem(indexed_tuple, i)
      {node.id, node}
    end)
  end

  defp topo_sort_with_hash(indexed, must_precede) do
    n = length(indexed)

    # Build adjacency + in-degree
    {adj, in_deg} =
      Enum.reduce(must_precede, {%{}, Map.new(0..(n - 1), &{&1, 0})}, fn {i, j}, {a, d} ->
        {Map.update(a, i, [j], &[j | &1]), Map.update(d, j, 1, &(&1 + 1))}
      end)

    # Compute structural hash for each child (for deterministic tie-breaking)
    hashes =
      Map.new(indexed, fn {node, i} ->
        {i, :erlang.phash2(node)}
      end)

    # Kahn's algorithm with hash-based priority
    ready =
      in_deg
      |> Enum.filter(fn {_, d} -> d == 0 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort_by(&Map.get(hashes, &1))

    do_topo_sort(ready, adj, in_deg, hashes, [])
  end

  defp do_topo_sort([], _adj, _in_deg, _hashes, acc), do: Enum.reverse(acc)

  defp do_topo_sort([current | rest], adj, in_deg, hashes, acc) do
    neighbors = Map.get(adj, current, [])

    {new_ready, in_deg} =
      Enum.reduce(neighbors, {[], in_deg}, fn neighbor, {ready, deg} ->
        new_deg = Map.get(deg, neighbor, 0) - 1
        deg = Map.put(deg, neighbor, new_deg)
        if new_deg == 0, do: {[neighbor | ready], deg}, else: {ready, deg}
      end)

    next_ready =
      (rest ++ new_ready)
      |> Enum.sort_by(&Map.get(hashes, &1))

    do_topo_sort(next_ready, adj, in_deg, hashes, [current | acc])
  end

  # --- Slicing ---

  @doc """
  Returns all node IDs that affect the given node (backward slice).

  The backward slice answers: "what does this expression depend on?"
  """
  @spec backward_slice(graph(), node_id()) :: [term()]
  def backward_slice(%SystemDependence{graph: g}, node_id) do
    if Graph.has_vertex?(g, node_id) do
      Graph.reaching(g, [node_id]) -- [node_id]
    else
      []
    end
  end

  @doc """
  Returns all node IDs affected by the given node (forward slice).

  The forward slice answers: "what does this expression influence?"
  """
  @spec forward_slice(graph(), node_id()) :: [term()]
  def forward_slice(%SystemDependence{graph: g}, node_id) do
    if Graph.has_vertex?(g, node_id) do
      Graph.reachable(g, [node_id]) -- [node_id]
    else
      []
    end
  end

  @doc """
  Returns node IDs on all paths from `source` to `sink`.

  The chop answers: "how does A influence B?"
  """
  @spec chop(graph(), node_id(), node_id()) :: [node_id()]
  def chop(graph, source, sink) do
    fwd = forward_slice(graph, source) |> MapSet.new()
    bwd = backward_slice(graph, sink) |> MapSet.new()
    MapSet.intersection(fwd, bwd) |> MapSet.to_list()
  end

  # --- Independence ---

  @doc """
  Returns true if two expressions are independent.

  Two expressions are independent when:
  1. No data flows between them in either direction
  2. They execute under the same conditions (same control dependencies)
  3. Their side effects don't conflict

  Independent expressions can be safely reordered.
  """
  @spec independent?(graph(), node_id(), node_id()) :: boolean()
  def independent?(%SystemDependence{graph: g, nodes: node_map} = sdg, id_x, id_y) do
    data_only = build_data_graph(g)

    ids_x = descendant_ids(node_map, id_x)
    ids_y = descendant_ids(node_map, id_y)

    not any_data_path?(data_only, ids_x, ids_y) and
      not any_data_path?(data_only, ids_y, ids_x) and
      same_control_deps?(sdg, id_x, id_y) and
      not conflicting_effects?(node_map, id_x, id_y)
  end

  defp descendant_ids(node_map, id) do
    case Map.get(node_map, id) do
      nil -> [id]
      node -> [id | Reach.IR.all_nodes(node) |> Enum.map(& &1.id)]
    end
  end

  defp any_data_path?(data_only, from_ids, to_ids) do
    Enum.any?(from_ids, fn from ->
      Enum.any?(to_ids, fn to ->
        from != to and data_path?(data_only, from, to)
      end)
    end)
  end

  # --- Querying nodes ---

  @doc """
  Returns all IR nodes, optionally filtered.

  ## Options

    * `:type` — filter by node type (`:call`, `:match`, `:var`, etc.)
    * `:module` — filter calls by module
    * `:function` — filter calls by function name
    * `:arity` — filter by arity

  ## Examples

      Reach.nodes(graph, type: :call)
      Reach.nodes(graph, type: :call, module: Enum)
      Reach.nodes(graph, type: :call, module: Enum, function: :map, arity: 2)
  """
  @spec nodes(graph(), keyword()) :: [Node.t()]
  def nodes(graph, opts \\ [])

  def nodes(%{nodes: node_map}, opts) do
    node_map
    |> Map.values()
    |> filter_nodes(opts)
  end

  @doc """
  Returns the IR node for a given ID, or `nil`.
  """
  @spec node(graph(), Node.id()) :: Node.t() | nil
  def node(%SystemDependence{nodes: nodes}, id), do: Map.get(nodes, id)

  @doc """
  Returns true if there's a data-dependence path from `source` to `sink`.
  """
  def data_flows?(%SystemDependence{nodes: node_map} = graph, source_id, sink_id) do
    source_ids = descendant_ids(node_map, source_id)
    sink_ids = descendant_ids(node_map, sink_id) |> MapSet.new()

    Enum.any?(source_ids, fn sid ->
      forward_slice(graph, sid)
      |> Enum.any?(&MapSet.member?(sink_ids, &1))
    end)
  end

  @doc """
  Returns true if `controller` has a control-dependence edge to `target`.
  """
  @spec controls?(graph(), node_id(), node_id()) :: boolean()
  def controls?(graph, controller_id, target_id) do
    control_deps(graph, target_id)
    |> Enum.any?(fn {id, _label} -> id == controller_id end)
  end

  @doc """
  Returns true if there's any dependence path between two nodes.
  """
  @spec depends?(graph(), node_id(), node_id()) :: boolean()
  def depends?(graph, id_a, id_b) do
    id_b in forward_slice(graph, id_a) or id_a in forward_slice(graph, id_b)
  end

  @doc """
  Returns true if the node has data dependents (its value is used elsewhere).
  """
  @spec has_dependents?(graph(), node_id()) :: boolean()
  def has_dependents?(graph, node_id) do
    forward_slice(graph, node_id) != []
  end

  @doc """
  Returns true if the path from `source` to `sink` passes through
  any node matching `predicate`.

  Useful for taint analysis — check if sanitization occurs between
  a source and sink.
  """
  @spec passes_through?(graph(), node_id(), node_id(), (Node.t() -> boolean())) :: boolean()
  def passes_through?(graph, source_id, sink_id, predicate) do
    chop(graph, source_id, sink_id)
    |> Enum.any?(fn id ->
      case node(graph, id) do
        nil -> false
        n -> predicate.(n)
      end
    end)
  end

  # --- Effects ---

  @doc """
  Returns true if the node is pure (no side effects).
  """
  @spec pure?(Node.t()) :: boolean()
  defdelegate pure?(node), to: Effects

  @doc """
  Returns the effect classification of a node.

  Possible values: `:pure`, `:read`, `:write`, `:io`, `:send`,
  `:receive`, `:exception`, `:nif`, `:unknown`.
  """
  @spec classify_effect(Node.t()) :: Effects.effect()
  defdelegate classify_effect(node), to: Effects, as: :classify

  # --- Graph access ---

  @doc """
  Returns all dependence edges in the graph.
  """
  @spec edges(graph()) :: [Graph.Edge.t()]
  def edges(%SystemDependence{graph: g}), do: Graph.edges(g)
  def edges(%Reach.Project{graph: g}), do: Graph.edges(g)

  @doc """
  Returns the control dependencies of a node.

  Each entry is `{controller_node_id, label}`.
  """
  @spec control_deps(graph(), Node.id()) :: [{Node.id(), term()}]
  def control_deps(%SystemDependence{graph: g}, node_id) do
    g
    |> Graph.in_edges(node_id)
    |> Enum.filter(fn e -> match?({:control, _}, e.label) end)
    |> Enum.map(fn e -> {e.v1, e.label} end)
  end

  @doc """
  Returns the data dependencies of a node.

  Each entry is `{source_node_id, variable_name}`.
  """
  @spec data_deps(graph(), Node.id()) :: [{Node.id(), atom()}]
  def data_deps(%SystemDependence{graph: g}, node_id) do
    g
    |> Graph.in_edges(node_id)
    |> Enum.filter(fn e -> match?({:data, _}, e.label) end)
    |> Enum.map(fn e ->
      {:data, var} = e.label
      {e.v1, var}
    end)
  end

  @doc """
  Returns the per-function PDG for a `{module, function, arity}` tuple.
  """
  @spec function_graph(graph(), {module() | nil, atom(), non_neg_integer()}) :: graph() | nil
  defdelegate function_graph(graph, function_id), to: SystemDependence, as: :function_pdg

  @doc """
  Performs a context-sensitive backward slice through call boundaries.

  Uses the Horwitz-Reps-Binkley two-phase algorithm to avoid
  impossible paths through call sites.
  """
  @spec context_sensitive_slice(graph(), Node.id()) :: [Node.id()]
  defdelegate context_sensitive_slice(graph, node_id), to: SystemDependence

  @doc """
  Returns the call graph as a `Graph.t()`.

  Vertices are `{module, function, arity}` tuples.
  """
  @spec call_graph(graph()) :: Graph.t()
  def call_graph(%SystemDependence{call_graph: cg}), do: cg

  @doc """
  Exports the graph to DOT format for Graphviz visualization.
  """
  @spec to_dot(graph()) :: {:ok, String.t()}
  def to_dot(%SystemDependence{graph: g}), do: Graph.to_dot(g)
  def to_dot(%Reach.Project{graph: g}), do: Graph.to_dot(g)

  @doc """
  Returns the underlying `Graph.t()` (libgraph) for direct traversal.

  Use this when you need graph operations that Reach doesn't expose —
  path finding, subgraphs, BFS/DFS, topological sort, etc.

      raw = Reach.to_graph(graph)
      Graph.vertices(raw) |> length()
      Graph.get_shortest_path(raw, id_a, id_b)
  """
  @spec to_graph(graph()) :: Graph.t()
  def to_graph(%SystemDependence{graph: g}), do: g
  def to_graph(%Reach.Project{graph: g}), do: g

  @doc """
  Returns node IDs directly connected to `node_id`.

  With no label filter, returns all neighbors (both incoming and outgoing).
  With a label, returns only neighbors connected by edges with that label.

      # All direct neighbors
      Reach.neighbors(graph, node_id)

      # Only nodes connected by :state_read edges
      Reach.neighbors(graph, node_id, :state_read)

      # Only data dependencies
      Reach.neighbors(graph, node_id, {:data, :x})
  """
  @spec neighbors(graph(), Node.id(), term() | nil) :: [Node.id()]
  def neighbors(graph, node_id, label \\ nil)

  def neighbors(%SystemDependence{graph: g}, node_id, nil) do
    in_ids = g |> Graph.in_neighbors(node_id)
    out_ids = g |> Graph.out_neighbors(node_id)
    Enum.uniq(in_ids ++ out_ids)
  end

  def neighbors(%SystemDependence{graph: g}, node_id, label) do
    in_edges = Graph.in_edges(g, node_id)
    out_edges = Graph.out_edges(g, node_id)

    (in_edges ++ out_edges)
    |> Enum.filter(&match_label?(&1.label, label))
    |> Enum.map(fn e -> if e.v1 == node_id, do: e.v2, else: e.v1 end)
    |> Enum.uniq()
  end

  # --- Dead code ---

  @doc """
  Returns nodes whose values are never used and have no side effects.

  A node is dead if:
  1. It is pure (no side effects)
  2. No observable output depends on it (return values or effectful calls)
  """
  @spec dead_code(graph()) :: [Node.t()]
  def dead_code(graph) do
    observables = observable_nodes(graph)
    observable_ids = MapSet.new(observables, & &1.id)

    alive_ids =
      observables
      |> Enum.flat_map(&backward_slice(graph, &1.id))
      |> MapSet.new()
      |> MapSet.union(observable_ids)

    all = nodes(graph)

    # Also mark parents of alive nodes as alive
    alive_ids = expand_alive_to_parents(all, alive_ids)

    find_dead_nodes(all, alive_ids)
  end

  defp observable_nodes(graph) do
    ret_ids = return_node_ids(graph)

    nodes(graph)
    |> Enum.filter(fn node ->
      not pure?(node) or MapSet.member?(ret_ids, node.id)
    end)
  end

  defp return_node_ids(graph) do
    all_clauses = nodes(graph, type: :clause)

    function_tails =
      all_clauses
      |> Enum.filter(&(&1.meta[:kind] == :function_clause))
      |> Enum.flat_map(&tail_expressions/1)

    fn_tails =
      all_clauses
      |> Enum.filter(&(&1.meta[:kind] == :fn_clause))
      |> Enum.flat_map(&tail_expressions/1)

    MapSet.new(function_tails ++ fn_tails, & &1.id)
  end

  defp tail_expressions(node) do
    last =
      case node do
        %{type: t, children: children}
        when t in [:block, :clause, :catch_clause, :rescue, :after] ->
          List.last(children)

        other ->
          other
      end

    case last do
      nil ->
        []

      %{type: t} when t in [:block, :clause, :catch_clause, :rescue, :after] ->
        tail_expressions(last)

      %{type: :case, children: children} ->
        clauses = Enum.filter(children, &(&1.type == :clause))
        Enum.flat_map(clauses, &tail_expressions/1)

      %{type: t, children: children} when t in [:try, :receive, :fn] ->
        Enum.flat_map(children, &tail_expressions/1)

      leaf ->
        [leaf]
    end
  end

  # --- Taint analysis ---

  @doc """
  Finds data flow paths from taint sources to dangerous sinks.

  Returns a list of `%{source: node, sink: node, path: [node_id], sanitized: boolean}`
  for each source→sink pair where data flows.

  Sources, sinks, and sanitizers can be specified as keyword filters
  (same format as `nodes/2`) or as predicate functions.

  ## Options

    * `:sources` — keyword filter or predicate identifying taint sources
    * `:sinks` — keyword filter or predicate identifying dangerous sinks
    * `:sanitizers` — keyword filter or predicate identifying sanitization
      points (optional)

  ## Examples

      Reach.taint_analysis(graph,
        sources: [type: :call, function: :get_param],
        sinks: [type: :call, module: System, function: :cmd, arity: 2],
        sanitizers: [type: :call, function: :sanitize]
      )

      # Predicates also work
      Reach.taint_analysis(graph,
        sources: &(&1.meta[:function] in [:params, :body_params]),
        sinks: [type: :call, module: Ecto.Adapters.SQL]
      )
  """
  @spec taint_analysis(graph(), keyword()) :: [map()]
  def taint_analysis(graph, opts) do
    source_filter = Keyword.fetch!(opts, :sources)
    sink_filter = Keyword.fetch!(opts, :sinks)
    sanitizer_filter = Keyword.get(opts, :sanitizers)

    all = nodes(graph)
    sources = filter_by(all, source_filter)
    sinks = filter_by(all, sink_filter)
    sanitizer_pred = to_predicate(all, sanitizer_filter)

    for source <- sources,
        sink <- sinks,
        data_flows?(graph, source.id, sink.id) do
      path = chop(graph, source.id, sink.id)

      sanitized =
        sanitizer_pred != nil and
          passes_through?(graph, source.id, sink.id, sanitizer_pred)

      %{
        source: source,
        sink: sink,
        path: path,
        sanitized: sanitized
      }
    end
  end

  # --- Private ---

  defp filter_by(nodes, filter) when is_list(filter), do: filter_nodes(nodes, filter)
  defp filter_by(nodes, filter) when is_function(filter), do: Enum.filter(nodes, filter)

  defp to_predicate(_all, nil), do: nil
  defp to_predicate(_all, pred) when is_function(pred), do: pred

  defp to_predicate(all, filter) when is_list(filter) do
    matching_ids = filter_nodes(all, filter) |> MapSet.new(& &1.id)
    fn node -> MapSet.member?(matching_ids, node.id) end
  end

  defp match_label?(label, label), do: true
  defp match_label?({tag, _}, tag) when is_atom(tag), do: true
  defp match_label?(_, _), do: false

  defp expand_alive_to_parents(all_nodes, alive_ids) do
    expand_alive_to_parents(all_nodes, alive_ids, MapSet.size(alive_ids))
  end

  defp expand_alive_to_parents(all_nodes, alive_ids, prev_size) do
    # Mark parent nodes alive if any child is alive
    ids =
      Enum.reduce(all_nodes, alive_ids, fn node, ids ->
        child_ids = Enum.map(node.children, & &1.id)

        if Enum.any?(child_ids, &MapSet.member?(ids, &1)) do
          MapSet.put(ids, node.id)
        else
          ids
        end
      end)

    # Mark all sub-expressions of alive match nodes alive
    ids =
      Enum.reduce(all_nodes, ids, fn node, ids ->
        expand_match_children(node, ids)
      end)

    # Mark all descendants of compiler-directive nodes as alive
    ids =
      Enum.reduce(all_nodes, ids, fn node, ids ->
        if compiler_directive?(node) do
          node
          |> Reach.IR.all_nodes()
          |> MapSet.new(& &1.id)
          |> MapSet.union(ids)
        else
          ids
        end
      end)

    # Mark all structural sub-expressions of alive composite nodes alive.
    # When a map, tuple, call, or operator is alive, its children that
    # contribute to its value are necessarily alive too.
    ids = expand_alive_to_descendants(all_nodes, ids)

    # Mark bindings alive when their variables are referenced in alive nodes.
    # This bridges the gap when PDG data-flow edges are missing for locals.
    ids = expand_alive_bindings(all_nodes, ids)

    # Mark clause parameters and guards alive (they are patterns, not dead code).
    ids = expand_clause_patterns_alive(all_nodes, ids)

    # Iterate until stable
    if MapSet.size(ids) == prev_size do
      ids
    else
      expand_alive_to_parents(all_nodes, ids, MapSet.size(ids))
    end
  end

  defp expand_alive_to_descendants(all_nodes, alive_ids) do
    new_ids = add_descendant_ids(all_nodes, alive_ids)

    if MapSet.size(new_ids) == MapSet.size(alive_ids) do
      new_ids
    else
      expand_alive_to_descendants(all_nodes, new_ids)
    end
  end

  defp add_descendant_ids(all_nodes, alive_ids) do
    Enum.reduce(all_nodes, alive_ids, fn node, ids ->
      cond do
        not MapSet.member?(ids, node.id) -> ids
        structural_composite?(node) -> add_all_descendant_ids(node, ids)
        node.type == :case -> add_case_subject_ids(node, ids)
        true -> ids
      end
    end)
  end

  defp add_case_subject_ids(node, ids) do
    node.children
    |> Enum.reject(&plain_clause?/1)
    |> Enum.flat_map(&Reach.IR.all_nodes/1)
    |> Enum.reduce(ids, fn child, acc -> MapSet.put(acc, child.id) end)
  end

  defp plain_clause?(%{type: :clause, meta: %{kind: :with_clause}}), do: false
  defp plain_clause?(%{type: :clause}), do: true
  defp plain_clause?(_), do: false

  defp add_all_descendant_ids(node, ids) do
    node.children
    |> Enum.flat_map(&Reach.IR.all_nodes/1)
    |> Enum.reduce(ids, fn child, acc -> MapSet.put(acc, child.id) end)
  end

  @structural_composites [
    :call,
    :map,
    :tuple,
    :list,
    :struct,
    :map_field,
    :binary_op,
    :unary_op,
    :cons,
    :fn,
    :guard
  ]

  defp structural_composite?(%{type: t}) when t in @structural_composites, do: true
  defp structural_composite?(_), do: false

  defp expand_alive_bindings(all_nodes, alive_ids) do
    # Collect variable references in alive nodes.
    alive_refs =
      all_nodes
      |> Enum.filter(&MapSet.member?(alive_ids, &1.id))
      |> Enum.flat_map(&IR.all_nodes/1)
      |> Enum.filter(fn n -> n.type == :var and n.meta[:binding_role] != :definition end)
      |> Enum.map(& &1.meta[:name])
      |> MapSet.new()

    # Also treat variable definitions inside alive binary patterns as
    # references, because size specifiers like <<x::binary-size(n)>>
    # are currently marked as definitions even though they use existing
    # variables.
    alive_binary_defs =
      all_nodes
      |> Enum.filter(fn n ->
        MapSet.member?(alive_ids, n.id) and n.type == :call and n.meta[:function] == :<<>>
      end)
      |> Enum.flat_map(&Reach.IR.all_nodes/1)
      |> Enum.filter(fn n -> n.type == :var and n.meta[:binding_role] == :definition end)
      |> Enum.map(& &1.meta[:name])
      |> MapSet.new()

    alive_refs = MapSet.union(alive_refs, alive_binary_defs)

    # Mark match nodes alive if they define any referenced variable
    all_nodes
    |> Enum.filter(fn n -> n.type == :match end)
    |> Enum.reduce(alive_ids, fn match, ids ->
      lhs_nodes =
        match.children
        |> List.first()
        |> List.wrap()
        |> Enum.flat_map(&Reach.IR.all_nodes/1)

      bound_vars =
        Enum.flat_map(lhs_nodes, fn
          %{type: :var, meta: %{binding_role: :definition, name: name}} -> [name]
          %{type: :struct, meta: %{name: {name, _, _}}} when is_atom(name) -> [name]
          _ -> []
        end)

      if Enum.any?(bound_vars, &MapSet.member?(alive_refs, &1)) do
        MapSet.put(ids, match.id)
      else
        ids
      end
    end)
  end

  defp expand_clause_patterns_alive(all_nodes, alive_ids) do
    Enum.reduce(all_nodes, alive_ids, fn node, ids ->
      expand_clause_pattern(node, ids)
    end)
  end

  defp expand_clause_pattern(%{type: t, meta: %{kind: :with_clause}} = node, ids)
       when t in [:clause, :catch_clause, :rescue] do
    if MapSet.member?(ids, node.id) do
      add_all_descendant_ids(node, ids)
    else
      ids
    end
  end

  defp expand_clause_pattern(%{type: t, children: children} = node, ids)
       when t in [:clause, :catch_clause, :rescue] do
    if MapSet.member?(ids, node.id) and length(children) > 1 do
      children
      |> Enum.drop(-1)
      |> Enum.flat_map(&Reach.IR.all_nodes/1)
      |> Enum.reduce(ids, fn child, acc -> MapSet.put(acc, child.id) end)
    else
      ids
    end
  end

  defp expand_clause_pattern(_, ids), do: ids

  defp expand_match_children(%{type: :match, id: id, children: children}, alive) do
    if MapSet.member?(alive, id) do
      children
      |> Enum.flat_map(&Reach.IR.all_nodes/1)
      |> Enum.reduce(alive, fn child, acc -> MapSet.put(acc, child.id) end)
    else
      alive
    end
  end

  defp expand_match_children(_, alive), do: alive

  defp find_dead_nodes(all_nodes, alive_ids) do
    impure_ids = collect_impure_ids(all_nodes)
    guard_ids = collect_guard_ids(all_nodes)
    cond_ids = collect_cond_condition_ids(all_nodes)

    all_nodes
    |> Enum.filter(&candidate_for_dead?/1)
    |> Enum.reject(fn node ->
      MapSet.member?(impure_ids, node.id) or
        MapSet.member?(alive_ids, node.id) or
        MapSet.member?(guard_ids, node.id) or
        MapSet.member?(cond_ids, node.id)
    end)
  end

  defp collect_guard_ids(all_nodes) do
    all_nodes
    |> Enum.filter(&(&1.type == :guard))
    |> Enum.flat_map(&Reach.IR.all_nodes/1)
    |> MapSet.new(& &1.id)
  end

  defp collect_cond_condition_ids(all_nodes) do
    cond_conditions =
      all_nodes
      |> Enum.filter(fn n ->
        n.type == :clause and n.meta[:kind] == :cond_clause
      end)
      |> Enum.flat_map(fn clause ->
        case clause.children do
          [condition | _] -> Reach.IR.all_nodes(condition)
          _ -> []
        end
      end)

    # Comprehension generators and filters
    comprehension_ids =
      all_nodes
      |> Enum.filter(&(&1.type in [:filter, :generator, :comprehension]))
      |> Enum.flat_map(&Reach.IR.all_nodes/1)

    MapSet.new(cond_conditions ++ comprehension_ids, & &1.id)
  end

  defp collect_impure_ids(all_nodes) do
    all_nodes
    |> Enum.filter(fn node ->
      node.type == :call and not pure?(node)
    end)
    |> Enum.flat_map(fn node ->
      Reach.IR.all_nodes(node) |> Enum.map(& &1.id)
    end)
    |> MapSet.new()
  end

  defp candidate_for_dead?(%Node{type: t} = node)
       when t in [:call, :binary_op, :unary_op, :match] do
    pure?(node) and not compiler_directive?(node) and not pattern_context?(node)
  end

  defp candidate_for_dead?(_), do: false

  @compiler_directives [
    :import,
    :alias,
    :require,
    :use,
    :doc,
    :moduledoc,
    :typedoc,
    :spec,
    :callback,
    :macrocallback,
    :impl,
    :type,
    :typep,
    :opaque,
    :behaviour,
    :defstruct,
    :defdelegate,
    :defmacro,
    :defmacrop,
    :defguard,
    :defguardp,
    :\\,
    :<<>>,
    :when
  ]

  defp compiler_directive?(%{type: :call, meta: %{function: f}})
       when f in @compiler_directives,
       do: true

  defp compiler_directive?(%{type: :call, meta: %{kind: :attribute}}), do: true

  defp compiler_directive?(%{type: :call, meta: %{function: :@}}), do: true

  defp compiler_directive?(_), do: false

  defp pattern_context?(%{type: :binary_op, meta: %{operator: :<>}, children: children}) do
    Enum.any?(children, fn
      %{type: :var, meta: %{binding_role: :definition}} -> true
      %{type: :var, meta: %{name: name}} -> Atom.to_string(name) |> String.starts_with?("_")
      %{type: :literal, meta: %{value: v}} when is_binary(v) -> true
      _ -> false
    end)
  end

  defp pattern_context?(_), do: false

  defp filter_nodes(nodes, []), do: nodes

  defp filter_nodes(nodes, [{:type, type} | rest]) do
    nodes |> Enum.filter(&(&1.type == type)) |> filter_nodes(rest)
  end

  defp filter_nodes(nodes, [{:module, module} | rest]) do
    nodes |> Enum.filter(&(&1.meta[:module] == module)) |> filter_nodes(rest)
  end

  defp filter_nodes(nodes, [{:function, function} | rest]) do
    nodes |> Enum.filter(&(&1.meta[:function] == function)) |> filter_nodes(rest)
  end

  defp filter_nodes(nodes, [{:arity, arity} | rest]) do
    nodes |> Enum.filter(&(&1.meta[:arity] == arity)) |> filter_nodes(rest)
  end

  defp filter_nodes(nodes, [_ | rest]) do
    filter_nodes(nodes, rest)
  end

  defp build_data_graph(graph) do
    graph
    |> Graph.edges()
    |> Enum.filter(fn e ->
      match?({:data, _}, e.label) or e.label in [:containment, :match_binding, :higher_order]
    end)
    |> then(&Graph.add_edges(Graph.new(), &1))
  end

  defp data_path?(data_graph, from, to) do
    if Graph.has_vertex?(data_graph, from) and Graph.has_vertex?(data_graph, to) do
      Graph.get_shortest_path(data_graph, from, to) != nil
    else
      false
    end
  end

  defp conflicting_effects?(node_map, id_x, id_y) do
    case {Map.get(node_map, id_x), Map.get(node_map, id_y)} do
      {%{} = x, %{} = y} ->
        Effects.conflicting?(Effects.classify(x), Effects.classify(y))

      _ ->
        true
    end
  end

  defp same_control_deps?(sdg, id_x, id_y) do
    deps_x = control_deps(sdg, id_x) |> MapSet.new()
    deps_y = control_deps(sdg, id_y) |> MapSet.new()
    MapSet.equal?(deps_x, deps_y)
  end

  defp parse_string(source, :erlang, opts) do
    Frontend.Erlang.parse_string(source, opts)
  end

  defp parse_string(source, _elixir, opts) do
    Frontend.Elixir.parse(source, opts)
  end

  defp parse_and_build(source, language, opts) do
    case parse_string(source, language, opts) do
      {:ok, ir_nodes} -> {:ok, SystemDependence.build(ir_nodes, opts)}
      {:error, _} = err -> err
    end
  end

  defp parse_plugin_file_and_build(path, opts) do
    case Plugin.parse_file(Plugin.resolve(opts), path, opts) do
      {:ok, nodes} -> {:ok, SystemDependence.build(nodes, opts)}
      {:error, _} = err -> err
      :error -> {:error, {:frontend_not_available, Path.extname(path)}}
    end
  end

  defp language_from_extension(path, opts) do
    case Path.extname(path) do
      ext when ext in [".erl", ".hrl"] -> :erlang
      ".gleam" -> :gleam
      ext -> Plugin.source_language(Plugin.resolve(opts), ext) || :elixir
    end
  end
end
