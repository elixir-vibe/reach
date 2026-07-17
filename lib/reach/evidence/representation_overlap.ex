defmodule Reach.Evidence.RepresentationOverlap do
  @moduledoc "Collects near-equivalent struct and bare-map representations across modules."

  alias Reach.IR
  alias Reach.Project.Query
  alias Reach.Source

  defmodule StructShape do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct [:module, :file, :line, keys: [], map_conversion_functions: []]
  end

  defmodule MapShape do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct [
      :module,
      :function,
      :variable,
      :file,
      :line,
      :column,
      :role,
      :normalized_into,
      projection?: false,
      projection_sources: [],
      keys: []
    ]
  end

  defmodule Fact do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct [
      :struct,
      :map,
      :similarity,
      :name_match?,
      shared_keys: [],
      struct_only_keys: [],
      map_only_keys: []
    ]
  end

  @default_min_shared_keys 3
  @default_min_similarity 0.8
  @presentation_module_segments ~w(
    adapter adapters converter exporter integration integrations introspect ir json merger normalizer
    persistence presentation presenter publisher registry renderer reporter schema schemas sender serializer
    storage thrift transformer transformers transport view web
  )
  @presentation_function_segments ~w(
    attrs camel cast classify convert describe detailed dump encode external format json map metadata
    normalise normalize parse payload project render safe serialize snake summarize summary unwrap
  )
  @boundary_variable_names ~w(attrs meta metadata optional_params params payload request row)
  @boundary_call_functions ~w(cmd)a
  @constructor_functions [:build, :from_map, :from_map!, :new, :new!]

  @doc "Collects cross-module struct/bare-map shape overlaps."
  @spec collect_project(Reach.Project.t(), keyword()) :: [Fact.t()]
  def collect_project(project, opts \\ []) do
    min_shared_keys = Keyword.get(opts, :min_shared_keys, @default_min_shared_keys)
    min_similarity = Keyword.get(opts, :min_similarity, @default_min_similarity)
    structs = collect_structs(project)
    maps = collect_maps(project)

    for struct <- structs,
        map <- maps,
        struct.module != map.module,
        fact = overlap_fact(struct, map),
        length(fact.shared_keys) >= min_shared_keys,
        fact.similarity >= min_similarity do
      fact
    end
    |> Enum.sort_by(&fact_sort_key/1)
  end

  @doc "Collects source-declared struct shapes."
  @spec collect_structs(Reach.Project.t()) :: [StructShape.t()]
  def collect_structs(project) do
    project
    |> Source.project_files()
    |> Enum.flat_map(&structs_in_file/1)
    |> Enum.sort_by(&{&1.file, &1.line || 0, &1.module})
  end

  @doc "Collects source bare-map construction shapes."
  @spec collect_maps(Reach.Project.t()) :: [MapShape.t()]
  def collect_maps(%{nodes: nodes, call_graph: _call_graph} = project) when is_map(nodes) do
    function_index = Query.function_index(project)
    parents = direct_parent_index(nodes)
    return_normalizations = return_normalization_index(nodes, function_index, parents)

    nodes
    |> Map.values()
    |> Enum.filter(&bare_map?(&1, function_index, parents))
    |> Enum.flat_map(&map_shape(&1, function_index, parents, return_normalizations))
    |> Enum.sort_by(&{&1.file, &1.line || 0, &1.column || 0})
  end

  def collect_maps(_incomplete_project), do: []

  defp structs_in_file(file) do
    with {:ok, source} <- File.read(file),
         {:ok, ast} <- Code.string_to_quoted(source, columns: true, emit_warnings: false) do
      collect_module_structs(ast, file, nil)
    else
      _error -> []
    end
  end

  defp collect_module_structs(ast, file, parent) do
    ast
    |> statements()
    |> Enum.flat_map(fn
      {:defmodule, _meta, [module_ast, block]} ->
        module_struct_shapes(module_ast, block, file, parent)

      _statement ->
        []
    end)
  end

  defp module_struct_shapes(module_ast, block, file, parent) do
    with {:ok, module} <- nested_module_name(module_ast, parent),
         {:ok, body} <- Reach.AST.keyword_fetch(block, :do) do
      own =
        case direct_defstruct(body) do
          {:ok, line, keys} ->
            [
              %StructShape{
                module: module,
                file: file,
                line: line,
                keys: keys,
                map_conversion_functions: map_conversion_functions(body)
              }
            ]

          :error ->
            []
        end

      Enum.concat(own, collect_module_structs(body, file, module))
    else
      _unsupported -> []
    end
  end

  defp nested_module_name(
         {:__aliases__, _meta, [{:__MODULE__, _module_meta, _context} | parts]},
         parent
       )
       when is_atom(parent) and not is_nil(parent),
       do: concat_module([parent | parts])

  defp nested_module_name({:__aliases__, _meta, [:"Elixir" | parts]}, _parent),
    do: concat_module(parts)

  defp nested_module_name({:__aliases__, _meta, parts}, nil),
    do: concat_module(parts)

  defp nested_module_name({:__aliases__, _meta, parts}, parent),
    do: concat_module([parent | parts])

  defp nested_module_name(_dynamic, _parent), do: :error

  defp concat_module(parts) do
    if Enum.all?(parts, &is_atom/1), do: {:ok, Module.concat(parts)}, else: :error
  end

  defp direct_defstruct(body) do
    body
    |> statements()
    |> Enum.find_value(:error, &defstruct_shape/1)
  end

  defp defstruct_shape({:defstruct, meta, arguments}) when is_list(arguments) do
    case struct_keys(arguments) do
      [] -> :error
      keys -> {:ok, meta[:line], keys}
    end
  end

  defp defstruct_shape(_statement), do: nil

  defp map_conversion_functions(body) do
    body
    |> statements()
    |> Enum.flat_map(fn
      {kind, _meta, [head, _block]} when kind in [:def, :defp] ->
        case function_name(head) do
          name
          when name in [
                 :as_map,
                 :from_map,
                 :from_map!,
                 :serialize,
                 :to_external,
                 :to_map,
                 :unwrap
               ] ->
            [name]

          _other ->
            []
        end

      _statement ->
        []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp function_name({:when, _meta, [head | _guards]}), do: function_name(head)
  defp function_name({name, _meta, args}) when is_atom(name) and is_list(args), do: name
  defp function_name(_head), do: nil

  defp struct_keys([fields]) when is_list(fields), do: struct_keys(fields)

  defp struct_keys(fields) when is_list(fields) do
    fields
    |> Enum.flat_map(fn
      key when is_atom(key) -> [key]
      {key, _default} when is_atom(key) -> [key]
      _dynamic -> []
    end)
    |> Enum.reject(&(&1 == :__struct__))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp struct_keys(_dynamic), do: []

  defp bare_map?(%{type: :map, source_span: span} = node, function_index, parents)
       when is_map(span) do
    not explicit_struct_map?(node) and not pattern_map?(node, function_index, parents) and
      map_keys(node) != []
  end

  defp bare_map?(_node, _function_index, _parents), do: false

  defp explicit_struct_map?(node) do
    Enum.any?(node.children, &(map_field_literal_key(&1) == :__struct__))
  end

  defp pattern_map?(node, function_index, parents) do
    Enum.any?(IR.all_nodes(node), &(&1.meta[:binding_role] == :definition)) or
      function_head_pattern?(node, function_index, parents)
  end

  defp function_head_pattern?(node, function_index, parents) do
    with {_module, _name, arity} <- Map.get(function_index.node_to_function, node.id),
         %{type: :clause} = clause <- ancestor_of_type(node, parents, :clause) do
      clause.children
      |> Enum.take(arity)
      |> Enum.any?(fn argument -> Enum.any?(IR.all_nodes(argument), &(&1.id == node.id)) end)
    else
      _not_function_head -> false
    end
  end

  defp ancestor_of_type(node, parents, type) do
    case Map.get(parents, node.id) do
      %{type: ^type} = parent -> parent
      nil -> nil
      parent -> ancestor_of_type(parent, parents, type)
    end
  end

  defp map_shape(node, function_index, parents, return_normalizations) do
    keys = map_keys(node)
    function = Map.get(function_index.node_to_function, node.id)
    variable = assigned_variable(node, parents)

    case function do
      {module, _name, _arity} when is_atom(module) and module != nil ->
        span = node.source_span
        {projection?, projection_sources} = projection_profile(node)

        [
          %MapShape{
            module: module,
            function: function,
            variable: variable,
            file: span[:file],
            line: span[:start_line],
            column: span[:start_col],
            role:
              if(accumulator_map?(node, parents),
                do: :accumulator,
                else: map_role(variable, function)
              ),
            normalized_into:
              normalization_target(node, parents) ||
                assigned_variable_normalization(variable, function, function_index) ||
                returned_map_normalization(node, function, parents, return_normalizations),
            projection?: projection?,
            projection_sources: projection_sources,
            keys: keys
          }
        ]

      _unknown_function ->
        []
    end
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

    projection? = fields != [] and matching / length(fields) >= @default_min_similarity
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

  defp normalization_target(node, parents, remaining \\ 3)
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
       when function in [:struct, :struct!],
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
       when is_atom(module) and module != nil do
    if presentation_module?(module) or presentation_function?(function),
      do: :boundary_call,
      else: {:call, module, function}
  end

  defp call_normalization_target(
         %{meta: %{module: nil, function: function}},
         _parents,
         _remaining
       )
       when function in @boundary_call_functions,
       do: :boundary_call

  defp call_normalization_target(_call, _parents, _remaining), do: nil

  defp struct_source?(%{type: :struct}), do: true

  defp struct_source?(%{type: :call, meta: %{function: function}})
       when function in [:build_struct, :struct, :struct!],
       do: true

  defp struct_source?(_other), do: false

  defp return_normalization_index(nodes, function_index, parents) do
    nodes
    |> Map.values()
    |> Enum.filter(&match?(%{type: :call}, &1))
    |> Enum.group_by(&call_target(&1, function_index), &normalization_target(&1, parents))
    |> Map.delete(nil)
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
      %{type: type, children: children} = parent when type in [:block, :clause] ->
        List.last(children).id == node.id and
          (type == :clause or returned_expression?(parent, parents))

      _not_returned ->
        false
    end
  end

  defp accumulator_map?(node, parents) do
    case Map.get(parents, node.id) do
      %{type: :call, meta: %{module: Enum, function: function}, children: children}
      when function in [:map_reduce, :reduce, :reduce_while, :scan] ->
        Enum.any?(Enum.drop(children, 1), &(&1.id == node.id))

      %{type: type} = parent when type in [:block, :list, :tuple] ->
        accumulator_map?(parent, parents)

      _not_an_accumulator ->
        false
    end
  end

  defp map_role(variable, {module, function, _arity}) do
    cond do
      accumulator_name?(variable) -> :accumulator
      boundary_variable_name?(variable) -> :presentation
      presentation_function?(function) -> :presentation
      presentation_module?(module) -> :presentation
      true -> :domain
    end
  end

  defp accumulator_name?(nil), do: false

  defp accumulator_name?(name) do
    name = to_string(name)
    name in ["acc", "initial_acc"] or String.ends_with?(name, "_acc")
  end

  defp boundary_variable_name?(nil), do: false

  defp boundary_variable_name?(name) do
    name = to_string(name)

    name in @boundary_variable_names or
      Enum.any?(@boundary_variable_names, &String.ends_with?(name, "_#{&1}"))
  end

  defp presentation_function?(function) do
    function
    |> to_string()
    |> String.split("_", trim: true)
    |> Enum.map(&String.trim_trailing(String.trim_trailing(&1, "!"), "?"))
    |> Enum.any?(&(&1 in @presentation_function_segments))
  end

  defp presentation_module?(module) do
    if module |> Atom.to_string() |> String.starts_with?("Elixir.") do
      module
      |> Module.split()
      |> Enum.flat_map(&(&1 |> Macro.underscore() |> String.split("_", trim: true)))
      |> Enum.any?(&(&1 in @presentation_module_segments))
    else
      false
    end
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

  defp assigned_variable_normalization(nil, _function, _function_index), do: nil

  defp assigned_variable_normalization(variable, function, function_index) do
    function_index.by_module
    |> Map.get(function, [])
    |> List.first()
    |> case do
      nil -> nil
      function_node -> normalized_variable_target(function_node, variable)
    end
  end

  defp normalized_variable_target(function_node, variable) do
    function_node
    |> IR.all_nodes()
    |> Enum.find_value(fn
      %{type: :call, meta: %{function: function}, children: [_target, argument | _]}
      when function in [:struct, :struct!] ->
        if variable_name(argument) == variable, do: :struct_constructor

      %{type: :call, meta: %{module: module, function: function}, children: children}
      when is_atom(module) and not is_nil(module) and
             function in @constructor_functions ->
        if Enum.any?(children, &(variable_name(&1) == variable)), do: {:call, module, function}

      _other ->
        nil
    end)
  end

  defp variable_name(%{type: :var, meta: %{name: name}}), do: name
  defp variable_name(_node), do: nil

  defp overlap_fact(struct, map) do
    struct_keys = MapSet.new(struct.keys)
    map_keys = MapSet.new(map.keys)
    shared = MapSet.intersection(struct_keys, map_keys)
    union = MapSet.union(struct_keys, map_keys)

    %Fact{
      struct: struct,
      map: map,
      similarity: MapSet.size(shared) / max(MapSet.size(union), 1),
      name_match?: entity_name_match?(struct, map),
      shared_keys: shared |> MapSet.to_list() |> Enum.sort(),
      struct_only_keys:
        struct_keys |> MapSet.difference(map_keys) |> MapSet.to_list() |> Enum.sort(),
      map_only_keys: map_keys |> MapSet.difference(struct_keys) |> MapSet.to_list() |> Enum.sort()
    }
  end

  defp entity_name_match?(struct, map) do
    entity = struct.module |> Module.split() |> List.last() |> Macro.underscore()

    [map.variable, elem(map.function, 1), map.module |> Module.split() |> List.last()]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Macro.underscore(to_string(&1)))
    |> Enum.any?(&name_contains_entity?(&1, entity))
  end

  defp name_contains_entity?(name, entity) do
    name
    |> String.split("_", trim: true)
    |> Enum.any?(&(&1 == entity or singular(&1) == singular(entity)))
  end

  defp singular(name) do
    cond do
      String.ends_with?(name, "ies") -> String.replace_suffix(name, "ies", "y")
      String.ends_with?(name, "s") -> String.trim_trailing(name, "s")
      true -> name
    end
  end

  defp fact_sort_key(fact) do
    {
      -fact.similarity,
      inspect(fact.struct.module),
      fact.map.file,
      fact.map.line || 0,
      inspect(fact.shared_keys)
    }
  end

  defp direct_parent_index(nodes) do
    Enum.reduce(nodes, %{}, fn {_id, node}, parents ->
      Enum.reduce(node.children, parents, &Map.put_new(&2, &1.id, node))
    end)
  end

  defp statements({:__block__, _meta, statements}), do: statements
  defp statements(body), do: [body]
end
