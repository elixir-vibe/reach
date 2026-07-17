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
  @presentation_module_segments ~w(json presenter renderer reporter serializer view)

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

    nodes
    |> Map.values()
    |> Enum.filter(&bare_map?/1)
    |> Enum.flat_map(&map_shape(&1, function_index, parents))
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

  defp nested_module_name({:__aliases__, _meta, [:"Elixir" | parts]}, _parent),
    do: {:ok, Module.concat(parts)}

  defp nested_module_name({:__aliases__, _meta, parts}, nil),
    do: {:ok, Module.concat(parts)}

  defp nested_module_name({:__aliases__, _meta, parts}, parent),
    do: {:ok, Module.concat([parent | parts])}

  defp nested_module_name(_dynamic, _parent), do: :error

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
          name when name in [:as_map, :serialize, :to_external, :to_map] -> [name]
          _other -> []
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

  defp bare_map?(%{type: :map, source_span: span} = node) when is_map(span) do
    not pattern_map?(node) and map_keys(node) != []
  end

  defp bare_map?(_node), do: false

  defp pattern_map?(node) do
    node
    |> IR.all_nodes()
    |> Enum.any?(&(&1.meta[:binding_role] == :definition))
  end

  defp map_shape(node, function_index, parents) do
    keys = map_keys(node)
    function = Map.get(function_index.node_to_function, node.id)

    case function do
      {module, _name, _arity} when is_atom(module) and module != nil ->
        span = node.source_span
        {projection?, projection_sources} = projection_profile(node)

        [
          %MapShape{
            module: module,
            function: function,
            variable: assigned_variable(node, parents),
            file: span[:file],
            line: span[:start_line],
            column: span[:start_col],
            role: map_role(assigned_variable(node, parents), function),
            normalized_into: normalization_target(node, parents),
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

  defp map_field_key(%{
         type: :map_field,
         children: [%{type: :literal, meta: %{value: key}}, _value]
       })
       when is_atom(key),
       do: [key]

  defp map_field_key(_field), do: []

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
    case value do
      %{
        type: :call,
        meta: %{kind: kind, function: ^key},
        children: [%{type: :var, meta: %{name: source}} | _]
      }
      when kind in [:field_access, :remote] ->
        source

      _transformed_value ->
        nil
    end
  end

  defp projected_field_source(_field), do: nil

  defp normalization_target(node, parents, remaining \\ 3)
  defp normalization_target(_node, _parents, 0), do: nil

  defp normalization_target(node, parents, remaining) do
    case Map.get(parents, node.id) do
      %{type: :call, meta: %{module: module}} when is_atom(module) and module != nil -> module
      nil -> nil
      parent -> normalization_target(parent, parents, remaining - 1)
    end
  end

  defp map_role(variable, {module, function, _arity}) do
    cond do
      accumulator_name?(variable) -> :accumulator
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

  defp presentation_function?(function) do
    function
    |> to_string()
    |> String.split("_", trim: true)
    |> Enum.any?(&(&1 in ~w(describe encode external json map render safe serialize)))
  end

  defp presentation_module?(module) do
    module
    |> Module.split()
    |> Enum.flat_map(&(&1 |> Macro.underscore() |> String.split("_", trim: true)))
    |> Enum.any?(&(&1 in @presentation_module_segments))
  end

  defp assigned_variable(node, parents) do
    case Map.get(parents, node.id) do
      %{type: :match, children: [left, right]} when right.id == node.id -> variable_name(left)
      _parent -> nil
    end
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
