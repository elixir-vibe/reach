defmodule Reach.Evidence.RepresentationOverlap do
  @moduledoc "Collects near-equivalent struct and bare-map representations across modules."

  alias __MODULE__.MapCollector
  alias __MODULE__.Semantics
  alias Reach.Source

  defmodule StructShape do
    @moduledoc "A source-declared struct and its field shape."

    @type t :: %__MODULE__{
            module: module(),
            file: Path.t(),
            line: pos_integer() | nil,
            keys: [atom()],
            map_conversion_functions: [atom()]
          }

    defstruct [:module, :file, :line, keys: [], map_conversion_functions: []]
  end

  defmodule MapShape do
    @moduledoc "A bare-map construction and its observed shape and provenance."

    @type normalization_target ::
            nil | :boundary_call | :struct_constructor | {:call, atom(), atom()}
    @type role :: :accumulator | :domain | :presentation
    @type function_id :: {module(), atom(), non_neg_integer()}
    @type t :: %__MODULE__{
            module: module(),
            function: function_id(),
            variable: atom() | nil,
            file: Path.t(),
            line: pos_integer() | nil,
            column: pos_integer() | nil,
            role: role(),
            normalized_into: normalization_target(),
            projection?: boolean(),
            projection_sources: [atom()],
            keys: [atom()]
          }

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
    @moduledoc "Shape-overlap evidence joining a struct with a bare map."

    @type t :: %__MODULE__{
            struct: Reach.Evidence.RepresentationOverlap.StructShape.t(),
            map: Reach.Evidence.RepresentationOverlap.MapShape.t(),
            similarity: float(),
            name_match?: boolean(),
            shared_keys: [atom()],
            struct_only_keys: [atom()],
            map_only_keys: [atom()]
          }

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
  defdelegate collect_maps(project), to: MapCollector, as: :collect

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
      own = own_struct_shape(module, body, file)
      Enum.concat(own, collect_module_structs(body, file, module))
    else
      _unsupported -> []
    end
  end

  defp own_struct_shape(module, body, file) do
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
        map_conversion_name(head)

      _statement ->
        []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp map_conversion_name(head) do
    name = function_name(head)
    if Semantics.map_conversion_function?(name), do: [name], else: []
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

  defp statements({:__block__, _meta, statements}), do: statements
  defp statements(body), do: [body]
end
