defmodule Reach.Project.Query do
  @moduledoc "Query API for filtering and searching project nodes and edges."

  alias Reach.IR.Helpers, as: IRHelpers

  @default_value_lineage_nodes 200
  @function_index_cache_key {__MODULE__, :function_index}
  @value_predecessor_index_cache_key {__MODULE__, :value_predecessor_index}

  def function_index(project) do
    case Map.get(project, :cache_key) do
      nil ->
        build_function_index(project)

      cache_key ->
        signature = {cache_key, project.nodes, project.call_graph}

        case Process.get(@function_index_cache_key) do
          {^signature, index} ->
            index

          _miss ->
            index = build_function_index(project)
            Process.put(@function_index_cache_key, {signature, index})
            index
        end
    end
  end

  def reset_cache do
    Process.delete(@function_index_cache_key)
    Process.delete(@value_predecessor_index_cache_key)
    :ok
  end

  @doc "Indexes direct value-producing predecessors for all project nodes."
  @spec value_predecessor_index(Reach.Project.t()) :: %{
          optional(Reach.IR.Node.id()) => [Reach.IR.Node.id()]
        }
  def value_predecessor_index(project) do
    case Map.get(project, :cache_key) do
      nil ->
        build_value_predecessor_index(project)

      cache_key ->
        signature = {cache_key, project.graph}

        case Process.get(@value_predecessor_index_cache_key) do
          {^signature, index} ->
            index

          _miss ->
            index = build_value_predecessor_index(project)
            Process.put(@value_predecessor_index_cache_key, {signature, index})
            index
        end
    end
  end

  defp build_value_predecessor_index(project) do
    project.graph
    |> Graph.edges()
    |> Enum.filter(&Reach.Analysis.value_edge?/1)
    |> Enum.reduce(%{}, fn edge, index ->
      Map.update(index, edge.v2, [edge.v1], &[edge.v1 | &1])
    end)
    |> Map.new(fn {node_id, predecessors} -> {node_id, Enum.uniq(predecessors)} end)
  end

  @doc "Returns direct value-producing predecessors for a project node."
  @spec value_predecessors(Reach.Project.t(), Reach.IR.Node.t() | Reach.IR.Node.id()) ::
          [Reach.IR.Node.t()]
  def value_predecessors(project, node_or_id) do
    node_id = node_id(node_or_id)

    project.graph
    |> Graph.in_edges(node_id)
    |> Enum.filter(&Reach.Analysis.value_edge?/1)
    |> Enum.map(& &1.v1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&Map.get(project.nodes, &1))
    |> Enum.reject(&is_nil/1)
  end

  @doc "Returns direct consumers of the value produced by a project node."
  @spec value_successors(Reach.Project.t(), Reach.IR.Node.t() | Reach.IR.Node.id()) ::
          [Reach.IR.Node.t()]
  def value_successors(project, node_or_id) do
    node_id = node_id(node_or_id)

    project.graph
    |> Graph.out_edges(node_id)
    |> Enum.filter(&Reach.Analysis.value_edge?/1)
    |> Enum.map(& &1.v2)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&Map.get(project.nodes, &1))
    |> Enum.reject(&is_nil/1)
  end

  @doc "Returns a bounded value-flow path between two project nodes, or nil."
  @spec value_path(
          Reach.Project.t(),
          Reach.IR.Node.t() | Reach.IR.Node.id(),
          Reach.IR.Node.t() | Reach.IR.Node.id(),
          keyword()
        ) :: [Reach.IR.Node.t()] | nil
  def value_path(project, from, to, opts \\ []) do
    max_nodes = Keyword.get(opts, :max_nodes, @default_value_lineage_nodes)
    from_id = node_id(from)
    to_id = node_id(to)

    case collect_value_path(project, [{from_id, [from_id]}], MapSet.new(), to_id, max_nodes) do
      nil -> nil
      path -> Enum.map(path, &Map.fetch!(project.nodes, &1))
    end
  end

  @doc "Returns terminal value origins that flow into a project node."
  @spec value_origins(Reach.Project.t(), Reach.IR.Node.t() | Reach.IR.Node.id(), keyword()) ::
          [Reach.IR.Node.t()]
  def value_origins(project, node_or_id, opts \\ []) do
    max_nodes = Keyword.get(opts, :max_nodes, @default_value_lineage_nodes)

    predecessor_index =
      Keyword.get_lazy(opts, :predecessor_index, fn -> value_predecessor_index(project) end)

    start_id = node_id(node_or_id)

    predecessor_index
    |> collect_value_origins([start_id], MapSet.new(), MapSet.new(), max_nodes)
    |> Enum.map(&Map.get(project.nodes, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.id)
  end

  def find_function(project, target) do
    index = function_index(project)

    case target do
      {mod, fun, arity} ->
        find_function_node(index, mod, fun, arity)

      fun_string when is_binary(fun_string) ->
        Enum.find(index.all, fn node ->
          IRHelpers.func_id_to_string({node.meta[:module], node.meta[:name], node.meta[:arity]}) =~
            fun_string
        end)

      _ ->
        nil
    end
  end

  def resolve_target(project, raw) when is_binary(raw) do
    case parse_file_line(raw) do
      {file, line} ->
        node = find_function_at_location(project, file, line)

        if node do
          {node.meta[:module], node.meta[:name], node.meta[:arity]}
        end

      nil ->
        resolve_function(project, raw)
    end
  end

  def resolve_target(project, raw), do: resolve_function(project, raw)

  def parse_file_line(raw) do
    case raw |> String.reverse() |> String.split(":", parts: 2) do
      [rev_digits, rev_file] when rev_file != "" ->
        digits = String.reverse(rev_digits)
        file = String.reverse(rev_file)

        case Integer.parse(digits) do
          {line, ""} -> {file, line}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def parse_function_reference(name) do
    with [qualified, arity_str] <- String.split(name, "/", parts: 2),
         {arity, ""} <- Integer.parse(arity_str),
         {mod_str, fun_str} <- split_module_function(qualified) do
      {mod_str, fun_str, arity}
    else
      _ -> nil
    end
  end

  def find_function_at_location(project, file, line) do
    index = function_index(project)

    index
    |> functions_for_file(file)
    |> Enum.filter(fn node -> node.source_span.start_line <= line end)
    |> Enum.max_by(& &1.source_span.start_line, fn -> nil end)
  end

  @doc "Returns functions selected by changed line ranges, without expanding ranges into lines."
  def functions_in_ranges(project, ranges_by_file) when is_map(ranges_by_file) do
    index = build_function_location_index(project)

    ranges_by_file
    |> Enum.flat_map(fn {file, ranges} ->
      index
      |> functions_for_file(file)
      |> functions_in_file_ranges(ranges)
    end)
    |> Enum.uniq_by(& &1.id)
  end

  def resolve_function(project, target) do
    case target do
      {mod, fun, arity} -> {mod, fun, arity}
      name when is_binary(name) -> resolve_function_by_name(project, name)
      _ -> nil
    end
  end

  def callers(project, target, depth \\ 4) do
    cg = project.call_graph
    variants = all_variants(cg, target)
    do_find_callers(cg, variants, depth, MapSet.new(variants), [])
  end

  def callees(project, target, depth \\ 3) do
    cg = project.call_graph
    variants = all_variants(cg, target)
    visited = MapSet.new(variants)

    initial =
      variants
      |> Enum.flat_map(&Graph.out_neighbors(cg, &1))
      |> Enum.filter(&mfa?/1)
      |> Enum.uniq()

    Enum.map(initial, fn callee ->
      new_visited = MapSet.put(visited, callee)
      children = walk_callees(cg, callee, depth, 2, new_visited)
      %{id: callee, depth: 1, children: children}
    end)
  end

  def func_location(project, func_id) do
    Enum.find_value(project.nodes, fn {_id, node} ->
      if node.type == :function_def and
           {node.meta[:module], node.meta[:name], node.meta[:arity]} == func_id,
         do: node
    end)
    |> case do
      nil -> "unknown"
      node -> IRHelpers.location(node)
    end
  end

  def mfa?({m, f, a}) when is_atom(m) and is_atom(f) and is_number(a), do: true
  def mfa?(_), do: false

  def all_variants(%Reach.Project{} = project, {nil, fun, arity}) do
    named_mod = Map.get(function_index(project).named_modules, {fun, arity})

    [{nil, fun, arity}, {named_mod, fun, arity}]
    |> Enum.uniq()
    |> Enum.filter(&Graph.has_vertex?(project.call_graph, &1))
  end

  def all_variants(%Reach.Project{} = project, {mod, fun, arity}) do
    all_variants(project.call_graph, {mod, fun, arity})
  end

  def all_variants(cg, {nil, fun, arity}) do
    named_mod = find_named_module(cg, fun, arity)

    [{nil, fun, arity}, {named_mod, fun, arity}]
    |> Enum.uniq()
    |> Enum.filter(&Graph.has_vertex?(cg, &1))
  end

  def all_variants(cg, {mod, fun, arity}) do
    [{nil, fun, arity}, {mod, fun, arity}]
    |> Enum.uniq()
    |> Enum.filter(&Graph.has_vertex?(cg, &1))
  end

  def file_matches?(_file, nil), do: true
  def file_matches?(nil, _path), do: false

  def file_matches?(file, path) do
    file == path or
      String.ends_with?(file, "/" <> path) or
      String.starts_with?(file, path)
  end

  defp build_function_index(project) do
    %{all: func_defs, by_file: by_file} = build_function_location_index(project)

    by_name_arity = Enum.group_by(func_defs, fn node -> {node.meta[:name], node.meta[:arity]} end)

    by_module =
      Enum.group_by(func_defs, fn node ->
        {node.meta[:module], node.meta[:name], node.meta[:arity]}
      end)

    by_module_name =
      func_defs
      |> Enum.group_by(fn node -> {node.meta[:module], node.meta[:name]} end)
      |> Map.new(fn {module_name, functions} ->
        {module_name, Enum.sort_by(functions, & &1.meta[:arity])}
      end)

    node_to_function = build_node_to_function_index(project)

    named_modules = named_modules(project.call_graph)

    %{
      by_name_arity: by_name_arity,
      by_module: by_module,
      by_module_name: by_module_name,
      by_file: by_file,
      node_to_function: node_to_function,
      named_modules: named_modules,
      all: func_defs
    }
  end

  defp build_function_location_index(project) do
    func_defs = for {_id, node} <- project.nodes, node.type == :function_def, do: node

    by_file =
      func_defs
      |> Enum.filter(& &1.source_span)
      |> Enum.group_by(& &1.source_span.file)
      |> Map.new(fn {file, functions} ->
        {file, Enum.sort_by(functions, & &1.source_span.start_line)}
      end)

    %{all: func_defs, by_file: by_file}
  end

  defp functions_for_file(index, file) do
    case Map.get(index.by_file, file, []) do
      [] ->
        index.all
        |> Enum.filter(fn node ->
          node.source_span != nil and file_matches?(node.source_span.file, file)
        end)
        |> Enum.sort_by(& &1.source_span.start_line)

      exact_functions ->
        exact_functions
    end
  end

  defp functions_in_file_ranges(functions, ranges) do
    ranges
    |> Enum.flat_map(&functions_in_range(functions, &1))
    |> Enum.uniq_by(& &1.id)
  end

  defp functions_in_range(functions, {first, last})
       when is_integer(first) and is_integer(last) and first <= last do
    preceding =
      functions
      |> Enum.take_while(&(&1.source_span.start_line <= first))
      |> List.last()

    started_in_range =
      Enum.filter(functions, fn function ->
        line = function.source_span.start_line
        line >= first and line <= last
      end)

    [preceding | started_in_range]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
  end

  defp functions_in_range(_functions, _invalid_range), do: []

  defp find_function_node(index, nil, fun, arity) do
    find_by_module(index, nil, fun, arity) || find_sole_candidate(index, fun, arity)
  end

  defp find_function_node(index, mod, fun, arity) do
    find_by_module(index, mod, fun, arity) || disambiguate_by_file(index, mod, fun, arity)
  end

  defp find_sole_candidate(index, fun, arity) do
    case Map.get(index.by_module, {nil, fun, arity}) do
      [single] -> single
      _ -> nil
    end
  end

  defp find_by_module(index, mod, fun, arity) do
    case Map.get(index.by_module, {mod, fun, arity}) do
      [first | _] -> first
      _ -> nil
    end
  end

  defp disambiguate_by_file(index, mod, fun, arity) when is_atom(mod) and mod != nil do
    path_hint =
      mod
      |> Atom.to_string()
      |> String.replace_leading("Elixir.", "")
      |> String.split(".")
      |> Enum.map_join("/", &Macro.underscore/1)

    find_in_file(index, fun, arity, path_hint) ||
      find_in_file_with_defaults(index, fun, arity, path_hint)
  end

  defp disambiguate_by_file(_index, _mod, _fun, _arity), do: nil

  defp find_in_file(index, fun, arity, path_hint) do
    candidates = Map.get(index.by_name_arity, {fun, arity}, [])

    Enum.find(candidates, fn node ->
      node.source_span != nil and String.ends_with?(node.source_span[:file], path_hint <> ".ex")
    end) ||
      Enum.find(candidates, fn node ->
        node.source_span != nil and String.contains?(node.source_span[:file], path_hint <> ".ex")
      end)
  end

  defp find_in_file_with_defaults(index, fun, arity, path_hint) do
    higher_arities =
      index.by_name_arity
      |> Enum.filter(fn {{f, a}, _nodes} -> f == fun and a > arity end)
      |> Enum.flat_map(fn {_key, nodes} -> nodes end)

    candidates =
      Enum.filter(higher_arities, fn node ->
        node.source_span != nil and
          (String.ends_with?(node.source_span[:file], path_hint <> ".ex") or
             String.contains?(node.source_span[:file], path_hint <> ".ex"))
      end)

    Enum.min_by(candidates, fn node -> node.meta[:arity] end, fn -> nil end)
  end

  defp split_module_function(qualified) do
    case qualified |> String.reverse() |> String.split(".", parts: 2) do
      [rev_fun, rev_mod] ->
        fun = String.reverse(rev_fun)
        mod = String.reverse(rev_mod)
        if fun != "" and mod != "", do: {mod, fun}

      _ ->
        nil
    end
  end

  defp resolve_function_by_name(project, name) do
    case parse_function_reference(name) do
      {mod_str, fun_str, arity} ->
        resolve_in_call_graph(project.call_graph, mod_str, fun_str, arity)

      nil ->
        resolve_unqualified_function_reference(project, name) ||
          resolve_by_function_name(project, name)
    end
  end

  defp resolve_unqualified_function_reference(project, name) do
    with [fun_str, arity_str] <- String.split(name, "/", parts: 2),
         {arity, ""} <- Integer.parse(arity_str),
         fun <- String.to_existing_atom(fun_str),
         [node | _] <- Map.get(function_index(project).by_name_arity, {fun, arity}, []) do
      {node.meta[:module], node.meta[:name], node.meta[:arity]}
    else
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp resolve_in_call_graph(cg, mod_str, fun_str, arity) do
    fun = String.to_existing_atom(fun_str)
    fuzzy_match_module(cg, mod_str, fun, arity)
  rescue
    ArgumentError -> nil
  end

  defp fuzzy_match_module(cg, mod_str, fun, arity) do
    downcased = String.downcase(mod_str)

    Graph.vertices(cg)
    |> Enum.find_value(fn
      {m, ^fun, ^arity} when is_atom(m) and m != nil ->
        actual = m |> Atom.to_string() |> String.replace_leading("Elixir.", "")

        if String.downcase(actual) == downcased do
          {m, fun, arity}
        end

      _ ->
        nil
    end)
  end

  defp resolve_by_function_name(project, name) do
    index = function_index(project)
    fun_atom = String.to_existing_atom(name)

    node = Enum.find(index.all, fn node -> node.meta[:name] == fun_atom end)

    if node do
      {node.meta[:module], node.meta[:name], node.meta[:arity]}
    end
  rescue
    ArgumentError -> nil
  end

  defp find_named_module(cg, fun, arity) do
    cg
    |> named_modules()
    |> Map.get({fun, arity})
  end

  defp named_modules(cg) do
    cg
    |> Graph.vertices()
    |> Enum.reduce(%{}, fn
      {module, function, arity}, acc when is_atom(module) and not is_nil(module) ->
        Map.put_new(acc, {function, arity}, module)

      _vertex, acc ->
        acc
    end)
  end

  defp build_node_to_function_index(project) do
    for({_id, node} <- project.nodes, node_to_function_root?(node), do: node)
    |> Enum.reduce(%{}, &index_node_function/2)
  end

  defp node_to_function_root?(%{type: :module_def}), do: true
  defp node_to_function_root?(%{type: :function_def, meta: %{module: nil}}), do: true
  defp node_to_function_root?(_node), do: false

  defp index_node_function(root, acc), do: index_node_function(root, nil, acc)

  defp index_node_function(%{type: :function_def} = node, _current_function, acc) do
    function_id = {node.meta[:module], node.meta[:name], node.meta[:arity]}
    index_node_descendants(node, function_id, acc)
  end

  defp index_node_function(node, current_function, acc) do
    index_node_descendants(node, current_function, acc)
  end

  defp index_node_descendants(node, current_function, acc) do
    acc = if current_function, do: Map.put_new(acc, node.id, current_function), else: acc
    Enum.reduce(node.children, acc, &index_node_function(&1, current_function, &2))
  end

  defp node_id(%{id: id}), do: id
  defp node_id(id), do: id

  defp collect_value_path(_project, [], _visited, _target, _remaining), do: nil
  defp collect_value_path(_project, _pending, _visited, _target, 0), do: nil

  defp collect_value_path(project, [{node_id, path} | pending], visited, target, remaining) do
    cond do
      node_id == target ->
        Enum.reverse(path)

      MapSet.member?(visited, node_id) ->
        collect_value_path(project, pending, visited, target, remaining)

      true ->
        successors =
          project.graph
          |> Graph.out_edges(node_id)
          |> Enum.filter(&Reach.Analysis.value_edge?/1)
          |> Enum.map(& &1.v2)
          |> Enum.uniq()
          |> Enum.reject(&MapSet.member?(visited, &1))
          |> Enum.map(&{&1, [&1 | path]})

        collect_value_path(
          project,
          pending ++ successors,
          MapSet.put(visited, node_id),
          target,
          remaining - 1
        )
    end
  end

  defp collect_value_origins(_predecessor_index, [], _visited, origins, _remaining), do: origins
  defp collect_value_origins(_predecessor_index, _pending, _visited, origins, 0), do: origins

  defp collect_value_origins(
         predecessor_index,
         [node_id | pending],
         visited,
         origins,
         remaining
       ) do
    if MapSet.member?(visited, node_id) do
      collect_value_origins(predecessor_index, pending, visited, origins, remaining)
    else
      predecessors = Map.get(predecessor_index, node_id, [])

      visited = MapSet.put(visited, node_id)

      if predecessors == [] do
        collect_value_origins(
          predecessor_index,
          pending,
          visited,
          MapSet.put(origins, node_id),
          remaining - 1
        )
      else
        collect_value_origins(
          predecessor_index,
          predecessors ++ pending,
          visited,
          origins,
          remaining - 1
        )
      end
    end
  end

  defp do_find_callers(_cg, [], _depth, _visited, acc), do: Enum.reverse(acc)
  defp do_find_callers(_cg, _frontier, 0, _visited, acc), do: Enum.reverse(acc)

  defp do_find_callers(cg, frontier, depth, visited, acc) do
    {new_callers, new_visited} =
      Enum.reduce(frontier, {[], visited}, fn f, {found, vis} ->
        callers =
          cg
          |> Graph.in_neighbors(f)
          |> Enum.filter(&mfa?/1)
          |> Enum.reject(&MapSet.member?(vis, &1))

        {Enum.reverse(callers, found), Enum.reduce(callers, vis, &MapSet.put(&2, &1))}
      end)

    acc = Enum.reduce(new_callers, acc, fn caller, acc -> [%{id: caller} | acc] end)

    if depth > 1,
      do: do_find_callers(cg, new_callers, depth - 1, new_visited, acc),
      else: Enum.reverse(acc)
  end

  defp walk_callees(_cg, _from, max_depth, current_depth, _visited)
       when current_depth > max_depth,
       do: []

  defp walk_callees(cg, from, max_depth, current_depth, visited) do
    neighbors = Graph.out_neighbors(cg, from) |> Enum.filter(&mfa?/1)

    Enum.flat_map(neighbors, fn callee ->
      expand_callee(cg, callee, max_depth, current_depth, visited)
    end)
  end

  defp expand_callee(cg, callee, max_depth, current_depth, visited) do
    if MapSet.member?(visited, callee) do
      []
    else
      new_visited = MapSet.put(visited, callee)
      children = walk_callees(cg, callee, max_depth, current_depth + 1, new_visited)
      [%{id: callee, depth: current_depth, children: children}]
    end
  end
end
