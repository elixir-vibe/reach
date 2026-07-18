defmodule Reach.Evidence.RepresentationOverlap.MapCollector do
  @moduledoc false

  alias Reach.Evidence.RepresentationOverlap.MapShape
  alias Reach.Evidence.RepresentationOverlap.Semantics
  alias Reach.IR
  alias Reach.IR.Helpers
  alias Reach.Project.Query

  @max_normalization_ancestors 3
  @min_projection_ratio 0.8
  @accumulator_functions [:map_reduce, :reduce, :reduce_while, :scan]
  @struct_functions [:struct, :struct!]
  @struct_source_functions [:build_struct, :struct, :struct!]

  @spec collect(Reach.Project.t()) :: [MapShape.t()]
  def collect(%{nodes: nodes, call_graph: _call_graph} = project) when is_map(nodes) do
    function_index = Query.function_index(project)
    parents = Helpers.direct_parent_index(nodes)
    return_normalizations = return_normalization_index(nodes, function_index, parents)

    nodes
    |> Map.values()
    |> Enum.filter(&bare_map?(&1, function_index, parents))
    |> Enum.flat_map(&map_shape(&1, function_index, parents, return_normalizations))
    |> Enum.sort_by(&{&1.file, &1.line || 0, &1.column || 0})
  end

  def collect(_incomplete_project), do: []

  defp bare_map?(%{type: :map, source_span: span} = node, function_index, parents)
       when is_map(span) do
    not explicit_struct_map?(node) and
      not Helpers.function_pattern?(node, function_index, parents) and
      map_keys(node) != []
  end

  defp bare_map?(_node, _function_index, _parents), do: false

  defp explicit_struct_map?(node) do
    Enum.any?(node.children, &(map_field_literal_key(&1) == :__struct__))
  end

  defp map_shape(node, function_index, parents, return_normalizations) do
    case Map.get(function_index.node_to_function, node.id) do
      {module, _name, _arity} = function when is_atom(module) and not is_nil(module) ->
        [build_map_shape(node, function, parents, return_normalizations)]

      _unknown_function ->
        []
    end
  end

  defp build_map_shape(node, function, parents, return_normalizations) do
    variable = assigned_variable(node, parents)
    span = node.source_span
    {projection?, projection_sources} = projection_profile(node)

    %MapShape{
      module: elem(function, 0),
      function: function,
      variable: variable,
      file: span[:file],
      line: span[:start_line],
      column: span[:start_col],
      role: map_role(node, variable, function, parents),
      normalized_into:
        normalization_target(node, parents) ||
          assigned_variable_normalization(variable, node, parents) ||
          returned_map_normalization(node, function, parents, return_normalizations),
      projection?: projection?,
      projection_sources: projection_sources,
      keys: map_keys(node)
    }
  end

  defp map_keys(node) do
    node.children
    |> Enum.flat_map(&map_field_key/1)
    |> Enum.reject(&(&1 == :__struct__))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp map_field_key(field) do
    case map_field_literal_key(field) do
      key when is_atom(key) -> [key]
      _dynamic -> []
    end
  end

  defp map_field_literal_key(%{
         type: :map_field,
         children: [%{type: :literal, meta: %{value: key}}, _value]
       }),
       do: key

  defp map_field_literal_key(_field), do: nil

  defp projection_profile(node) do
    fields = Enum.filter(node.children, &match?(%{type: :map_field}, &1))
    sources = Enum.map(fields, &projected_field_source/1)
    matching = Enum.count(sources, &(not is_nil(&1)))

    projection? = fields != [] and matching / length(fields) >= @min_projection_ratio
    {projection?, sources |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()}
  end

  defp projected_field_source(%{
         type: :map_field,
         children: [%{type: :literal, meta: %{value: key}}, value]
       }) do
    value
    |> IR.all_nodes()
    |> Enum.find_value(fn
      %{type: :call, meta: %{kind: kind, function: ^key}, children: [source | _]}
      when kind in [:field_access, :remote] ->
        projection_source_name(source)

      _other ->
        nil
    end)
  end

  defp projected_field_source(_field), do: nil

  defp projection_source_name(%{type: :var, meta: %{name: source}}), do: source

  defp projection_source_name(%{type: :call, meta: %{kind: :field_access, function: source}}),
    do: source

  defp projection_source_name(_dynamic), do: nil

  defp normalization_target(node, parents, remaining \\ @max_normalization_ancestors)
  defp normalization_target(_node, _parents, 0), do: nil

  defp normalization_target(node, parents, remaining) do
    case Map.get(parents, node.id) do
      %{type: :call} = call ->
        call_normalization_target(call, parents, remaining)

      %{type: type} = parent when type in [:block, :list, :map, :map_field, :match, :tuple] ->
        normalization_target(parent, parents, remaining - 1)

      _not_directly_normalized ->
        nil
    end
  end

  defp call_normalization_target(
         %{meta: %{function: function}},
         _parents,
         _remaining
       )
       when function in @struct_functions,
       do: :struct_constructor

  defp call_normalization_target(
         %{meta: %{module: Map, function: :merge}} = call,
         parents,
         remaining
       ) do
    if Enum.any?(call.children, &struct_source?/1),
      do: :struct_constructor,
      else: normalization_target(call, parents, remaining - 1)
  end

  defp call_normalization_target(
         %{meta: %{module: Access, function: :get}},
         _parents,
         _remaining
       ),
       do: :boundary_call

  defp call_normalization_target(
         %{meta: %{module: module, function: function}},
         _parents,
         _remaining
       )
       when is_atom(module) and not is_nil(module) do
    if Semantics.presentation_module?(module) or Semantics.presentation_function?(function),
      do: :boundary_call,
      else: {:call, module, function}
  end

  defp call_normalization_target(
         %{meta: %{module: nil, function: function}},
         _parents,
         _remaining
       ) do
    if Semantics.boundary_call?(function), do: :boundary_call
  end

  defp call_normalization_target(_call, _parents, _remaining), do: nil

  defp struct_source?(%{type: :struct}), do: true

  defp struct_source?(%{type: :call, meta: %{function: function}}),
    do: function in @struct_source_functions

  defp struct_source?(_other), do: false

  defp return_normalization_index(nodes, function_index, parents) do
    project_functions = Map.keys(function_index.by_module)

    nodes
    |> Map.values()
    |> Enum.filter(&match?(%{type: :call}, &1))
    |> Enum.group_by(&call_target(&1, function_index), &normalization_target(&1, parents))
    |> Map.take(project_functions)
    |> Enum.reduce(%{}, fn {target, normalizations}, index ->
      case Enum.uniq(normalizations) do
        [normalization] when not is_nil(normalization) -> Map.put(index, target, normalization)
        _not_consistently_normalized -> index
      end
    end)
  end

  defp call_target(
         %{id: id, meta: %{module: nil, function: function, arity: arity}},
         function_index
       ) do
    case Map.get(function_index.node_to_function, id) do
      {caller_module, _caller_name, _caller_arity} -> {caller_module, function, arity}
      _unknown_caller -> nil
    end
  end

  defp call_target(%{meta: %{module: module, function: function, arity: arity}}, _function_index)
       when is_atom(module),
       do: {module, function, arity}

  defp call_target(_dynamic, _function_index), do: nil

  defp returned_map_normalization(node, function, parents, return_normalizations) do
    if returned_expression?(node, parents), do: Map.get(return_normalizations, function)
  end

  defp returned_expression?(node, parents) do
    case Map.get(parents, node.id) do
      %{type: :clause, children: children} ->
        last_child?(children, node)

      %{type: :block, children: children} = parent ->
        last_child?(children, node) and returned_expression?(parent, parents)

      _not_returned ->
        false
    end
  end

  defp last_child?(children, %{id: id}), do: match?(%{id: ^id}, List.last(children))

  defp map_role(node, variable, {module, function, _arity}, parents) do
    cond do
      accumulator_map?(node, parents) -> :accumulator
      accumulator_name?(variable) -> :accumulator
      Semantics.boundary_variable?(variable) -> :presentation
      Semantics.presentation_function?(function) -> :presentation
      Semantics.presentation_module?(module) -> :presentation
      true -> :domain
    end
  end

  defp accumulator_map?(node, parents) do
    case Map.get(parents, node.id) do
      %{type: :call, meta: %{module: Enum, function: function}, children: children}
      when function in @accumulator_functions ->
        Enum.any?(Enum.drop(children, 1), &(&1.id == node.id))

      %{type: type} = parent when type in [:block, :list, :tuple] ->
        accumulator_map?(parent, parents)

      _not_an_accumulator ->
        false
    end
  end

  defp accumulator_name?(nil), do: false

  defp accumulator_name?(name) do
    name = to_string(name)
    name in ["acc", "initial_acc"] or String.ends_with?(name, "_acc")
  end

  defp assigned_variable(node, parents) do
    case Map.get(parents, node.id) do
      %{type: :match, children: [left, right]} when right.id == node.id ->
        variable_name(left)

      %{type: type} = parent when type in [:block, :map, :map_field] ->
        assigned_variable(parent, parents)

      _parent ->
        nil
    end
  end

  defp assigned_variable_normalization(nil, _node, _parents), do: nil

  defp assigned_variable_normalization(variable, node, parents) do
    case ancestor_of_type(node, parents, :clause) do
      nil -> nil
      clause -> normalized_variable_target(clause, variable, node)
    end
  end

  defp normalized_variable_target(clause, variable, map) do
    map_position = source_position(map)

    clause
    |> IR.all_nodes()
    |> Enum.filter(&(source_position(&1) > map_position))
    |> Enum.find_value(fn
      %{type: :call, meta: %{function: function}, children: [_target, argument | _]}
      when function in @struct_functions ->
        if variable_name(argument) == variable, do: :struct_constructor

      %{type: :call, meta: %{module: module, function: function}, children: children}
      when is_atom(module) and not is_nil(module) ->
        if Semantics.constructor_function?(function) and
             Enum.any?(children, &(variable_name(&1) == variable)),
           do: {:call, module, function}

      _other ->
        nil
    end)
  end

  defp ancestor_of_type(node, parents, type) do
    case Map.get(parents, node.id) do
      %{type: ^type} = parent -> parent
      nil -> nil
      parent -> ancestor_of_type(parent, parents, type)
    end
  end

  defp source_position(%{source_span: span}) when is_map(span),
    do: {span[:start_line] || 0, span[:start_col] || 0}

  defp source_position(_node), do: {0, 0}

  defp variable_name(%{type: :var, meta: %{name: name}}), do: name
  defp variable_name(_node), do: nil
end
