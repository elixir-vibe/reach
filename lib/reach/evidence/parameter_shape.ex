defmodule Reach.Evidence.ParameterShape do
  @moduledoc "Collects map-shape variation flowing into function parameters."

  alias Reach.Project.Query

  defmodule Occurrence do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct [:caller, :file, :line, :column, keys: [], literals: %{}]
  end

  defmodule Fact do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct [
      :target,
      :parameter,
      :parameter_index,
      :role,
      :file,
      :line,
      :entropy,
      intentional_dispatch?: false,
      tagged_variants?: false,
      callers: [],
      consumed_keys: [],
      core_keys: [],
      union_keys: [],
      optional_keys: [],
      variants: [],
      occurrences: []
    ]
  end

  @default_max_lineage_nodes 200
  @variant_tag_keys [:action, :event, :kind, :mode, :role, :status, :type]

  @non_contract_parameter_names [
    :acc,
    :assigns,
    :attrs,
    :config,
    :context,
    :metadata,
    :opts,
    :options,
    :params,
    :payload,
    :request,
    :response,
    :state
  ]

  @doc "Collects parameter map-shape facts from statically resolved project calls."
  @spec collect_project(Reach.Project.t()) :: [Fact.t()]
  def collect_project(%{nodes: nodes, call_graph: %Graph{}} = project) when is_map(nodes) do
    index = Query.function_index(project)
    predecessor_index = Query.value_predecessor_index(project)
    targets = call_targets(project.call_graph)

    project.nodes
    |> Map.values()
    |> Enum.filter(&(&1.type == :call))
    |> Enum.flat_map(&call_occurrences(&1, project, index, predecessor_index, targets))
    |> Enum.group_by(fn {target, parameter_index, _occurrence} -> {target, parameter_index} end)
    |> Enum.map(&parameter_fact(&1, project))
    |> Enum.sort_by(&{&1.file || "", &1.line || 0, &1.target, &1.parameter_index})
  end

  def collect_project(_incomplete_project), do: []

  defp call_targets(call_graph) do
    call_graph
    |> Graph.edges()
    |> Enum.reduce(%{}, fn
      %{label: {:call, node_id}, v2: target}, targets -> Map.put(targets, node_id, target)
      _edge, targets -> targets
    end)
  end

  defp call_occurrences(node, project, index, predecessor_index, targets) do
    with target when not is_nil(target) <- Map.get(targets, node.id),
         function when not is_nil(function) <- find_target_function(project, index, target) do
      canonical_target = function_id(function)
      caller = Map.get(index.node_to_function, node.id)

      node.children
      |> Enum.take(Map.get(node.meta, :arity, 0))
      |> Enum.with_index()
      |> Enum.flat_map(fn {argument, parameter_index} ->
        argument
        |> map_origins(project, predecessor_index)
        |> Enum.map(&{canonical_target, parameter_index, occurrence(&1, caller, node)})
      end)
    else
      _unresolved -> []
    end
  end

  defp map_origins(argument, project, predecessor_index) do
    predecessor_index
    |> collect_map_origins(
      [argument.id],
      project.nodes,
      MapSet.new(),
      [],
      @default_max_lineage_nodes
    )
    |> Enum.uniq_by(& &1.id)
  end

  defp collect_map_origins(_index, [], _nodes, _visited, maps, _remaining),
    do: Enum.reverse(maps)

  defp collect_map_origins(_index, _pending, _nodes, _visited, maps, 0),
    do: Enum.reverse(maps)

  defp collect_map_origins(index, [node_id | pending], nodes, visited, maps, remaining) do
    cond do
      MapSet.member?(visited, node_id) ->
        collect_map_origins(index, pending, nodes, visited, maps, remaining)

      literal_map?(Map.get(nodes, node_id)) ->
        collect_map_origins(
          index,
          pending,
          nodes,
          MapSet.put(visited, node_id),
          [Map.fetch!(nodes, node_id) | maps],
          remaining - 1
        )

      transparent_lineage?(Map.get(nodes, node_id)) ->
        predecessors = Map.get(index, node_id, [])

        collect_map_origins(
          index,
          Enum.reverse(predecessors, pending),
          nodes,
          MapSet.put(visited, node_id),
          maps,
          remaining - 1
        )

      true ->
        collect_map_origins(
          index,
          pending,
          nodes,
          MapSet.put(visited, node_id),
          maps,
          remaining - 1
        )
    end
  end

  defp transparent_lineage?(%{type: type}) when type in [:block, :match, :var], do: true
  defp transparent_lineage?(_node), do: false

  defp literal_map?(%{type: :map, children: children}) do
    keys = Enum.flat_map(children, &map_field_key/1)
    keys != [] and length(keys) == length(children)
  end

  defp literal_map?(_node), do: false

  defp occurrence(map, caller, call) do
    span = call.source_span || map.source_span || %{}

    %Occurrence{
      caller: caller,
      file: span[:file],
      line: span[:start_line],
      column: span[:start_col],
      keys: map_keys(map),
      literals: map_literals(map)
    }
  end

  defp parameter_fact({{target, parameter_index}, entries}, project) do
    occurrences = Enum.map(entries, &elem(&1, 2))
    function = find_target_function(project, Query.function_index(project), target)
    parameter = parameter_name(function, parameter_index)
    key_sets = Enum.map(occurrences, &MapSet.new(&1.keys))
    core = intersect_sets(key_sets)
    union = union_sets(key_sets)
    variants = occurrences |> Enum.map(& &1.keys) |> Enum.uniq() |> Enum.sort()
    span = function.source_span || %{}

    %Fact{
      target: target,
      parameter: parameter || "arg#{parameter_index + 1}",
      parameter_index: parameter_index,
      role: parameter_role(parameter),
      file: span[:file],
      line: span[:start_line],
      entropy: 1.0 - MapSet.size(core) / max(MapSet.size(union), 1),
      intentional_dispatch?: intentional_dispatch?(function, parameter_index),
      tagged_variants?: tagged_variants?(occurrences, core),
      callers: occurrences |> Enum.map(& &1.caller) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      consumed_keys: consumed_keys(function, parameter),
      core_keys: core |> MapSet.to_list() |> Enum.sort(),
      union_keys: union |> MapSet.to_list() |> Enum.sort(),
      optional_keys: union |> MapSet.difference(core) |> MapSet.to_list() |> Enum.sort(),
      variants: variants,
      occurrences: Enum.sort_by(occurrences, &{&1.file || "", &1.line || 0, &1.keys})
    }
  end

  defp find_target_function(_project, index, {nil, name, arity}) do
    case Map.get(index.by_name_arity, {name, arity}, []) |> Enum.uniq_by(&function_id/1) do
      [function] -> function
      _ambiguous -> nil
    end
  end

  defp find_target_function(project, _index, target), do: Query.find_function(project, target)

  defp tagged_variants?(occurrences, core) do
    core
    |> MapSet.to_list()
    |> Enum.filter(&(&1 in @variant_tag_keys))
    |> Enum.any?(fn key ->
      values = Enum.map(occurrences, &Map.get(&1.literals, key, :dynamic))
      :dynamic not in values and length(Enum.uniq(values)) > 1
    end)
  end

  defp consumed_keys(_function, nil), do: []

  defp consumed_keys(function, parameter) do
    function
    |> Reach.IR.all_nodes()
    |> Enum.flat_map(&consumed_key(&1, parameter))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp consumed_key(
         %{type: :call, meta: %{module: parameter, function: key, kind: kind}},
         parameter
       )
       when is_atom(key) and kind in [:field_access, :remote],
       do: [key]

  defp consumed_key(
         %{
           type: :call,
           meta: %{module: module, function: function},
           children: [map, %{type: :literal, meta: %{value: key}} | _]
         },
         parameter
       )
       when module in [Map, Access] and function in [:fetch, :fetch!, :get, :has_key?] and
              (is_atom(key) or is_binary(key)) do
    if bound_name(map) == parameter, do: [key], else: []
  end

  defp consumed_key(_node, _parameter), do: []

  defp intersect_sets([]), do: MapSet.new()
  defp intersect_sets([first | rest]), do: Enum.reduce(rest, first, &MapSet.intersection/2)
  defp union_sets(sets), do: Enum.reduce(sets, MapSet.new(), &MapSet.union/2)

  defp intentional_dispatch?(function, parameter_index) do
    patterns =
      function
      |> function_clauses()
      |> Enum.map(fn clause ->
        clause.children
        |> Enum.take(function.meta.arity)
        |> Enum.drop(parameter_index)
        |> List.first()
      end)

    length(patterns) >= 2 and Enum.count(patterns, &restrictive_pattern?/1) >= 2
  end

  defp restrictive_pattern?(%{type: type}) when type in [:literal, :map, :struct, :tuple],
    do: true

  defp restrictive_pattern?(%{type: :match, children: children}),
    do: Enum.any?(children, &restrictive_pattern?/1)

  defp restrictive_pattern?(_pattern), do: false

  defp parameter_name(nil, _index), do: nil

  defp parameter_name(function, index) do
    function
    |> function_clauses()
    |> List.first()
    |> case do
      nil ->
        nil

      clause ->
        clause.children |> Enum.take(function.meta.arity) |> Enum.at(index) |> bound_name()
    end
  end

  defp bound_name(%{type: :var, meta: %{name: name}}), do: name

  defp bound_name(%{type: :call, meta: %{function: :\\}, children: [parameter | _]}),
    do: bound_name(parameter)

  defp bound_name(%{type: :match, children: children}),
    do: Enum.find_value(children, &bound_name/1)

  defp bound_name(_pattern), do: nil

  defp parameter_role(name) when name in @non_contract_parameter_names, do: :non_contract
  defp parameter_role(_name), do: :domain

  defp map_keys(map) do
    map.children
    |> Enum.flat_map(&map_field_key/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp map_field_key(%{
         type: :map_field,
         children: [%{type: :literal, meta: %{value: key}}, _value]
       })
       when is_atom(key) or is_binary(key),
       do: [key]

  defp map_field_key(_field), do: []

  defp map_literals(map) do
    Map.new(map.children, fn
      %{
        type: :map_field,
        children: [
          %{type: :literal, meta: %{value: key}},
          %{type: :literal, meta: %{value: value}}
        ]
      } ->
        {key, value}

      %{type: :map_field, children: [%{type: :literal, meta: %{value: key}}, _value]} ->
        {key, :dynamic}
    end)
  end

  defp function_clauses(function), do: Enum.filter(function.children, &(&1.type == :clause))
  defp function_id(function), do: {function.meta.module, function.meta.name, function.meta.arity}
end
