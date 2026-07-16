defmodule Reach.Check.Changed.AccessStrictness do
  @moduledoc "Detects changed hunks that replace strict map contracts with lenient reads."

  alias Reach.Check.Changed.Range
  alias Reach.Check.Changed.SourceSnapshot
  alias Reach.Check.Changed.StrictnessDowngrade
  alias Reach.IR.Helpers, as: IRHelpers
  alias Reach.Project.Query

  @strict_kinds [:field_access, :fetch, :map_pattern]
  @kind_priority %{map_pattern: 0, fetch: 1, field_access: 2}

  @spec analyze(Reach.Project.t(), String.t(), map(), keyword()) :: [StrictnessDowngrade.t()]
  def analyze(project, base, changed_ranges, opts \\ []) do
    revision = SourceSnapshot.revision(base, opts)

    changed_ranges
    |> Enum.flat_map(fn {file, ranges} ->
      analyze_file(project, file, ranges, revision, opts)
    end)
    |> Enum.sort_by(&{&1.file, &1.new_line, &1.function, &1.key})
  end

  defp analyze_file(project, file, ranges, revision, opts) do
    with true <- elixir_file?(file),
         {:ok, old_source} <- SourceSnapshot.source(:old, file, revision, opts),
         {:ok, new_source} <- SourceSnapshot.source(:new, file, revision, opts),
         {:ok, old_accesses} <- accesses(old_source),
         {:ok, new_accesses} <- accesses(new_source) do
      ranges = Enum.map(ranges, &Range.normalize/1)
      pair_downgrades(project, file, ranges, old_accesses, new_accesses)
    else
      _unavailable -> []
    end
  end

  defp pair_downgrades(project, file, ranges, old_accesses, new_accesses) do
    old_counts = access_counts(old_accesses)
    new_counts = access_counts(new_accesses)

    ranges
    |> Enum.with_index()
    |> Enum.flat_map(fn {range, hunk_index} ->
      old_in_hunk = Enum.filter(old_accesses, &line_in_old?(&1.line, range))
      new_in_hunk = Enum.filter(new_accesses, &line_in_new?(&1.line, range))
      downgrade_hunk(project, file, hunk_index, old_in_hunk, new_in_hunk, old_counts, new_counts)
    end)
    |> Enum.uniq_by(&{&1.file, &1.new_line, &1.module, &1.function, &1.arity, &1.key})
  end

  defp downgrade_hunk(
         project,
         file,
         _hunk_index,
         old_accesses,
         new_accesses,
         old_counts,
         new_counts
       ) do
    new_accesses
    |> Enum.filter(&(&1.kind == :map_get))
    |> Enum.flat_map(fn lenient ->
      matching_strict =
        old_accesses
        |> Enum.filter(&(&1.signature == lenient.signature and &1.kind in @strict_kinds))
        |> Enum.sort_by(&{Map.fetch!(@kind_priority, &1.kind), &1.line})

      if matching_strict != [] and
           strictness_decreased?(lenient.signature, old_counts, new_counts) and
           leniency_increased?(lenient.signature, old_counts, new_counts) do
        [downgrade(project, file, List.first(matching_strict), lenient)]
      else
        []
      end
    end)
  end

  defp strictness_decreased?(signature, old_counts, new_counts) do
    count_kinds(old_counts, signature, @strict_kinds) >
      count_kinds(new_counts, signature, @strict_kinds)
  end

  defp leniency_increased?(signature, old_counts, new_counts) do
    count_kind(new_counts, signature, :map_get) > count_kind(old_counts, signature, :map_get)
  end

  defp count_kinds(counts, signature, kinds) do
    Enum.sum_by(kinds, &count_kind(counts, signature, &1))
  end

  defp count_kind(counts, signature, kind), do: Map.get(counts, {signature, kind}, 0)

  defp access_counts(accesses) do
    Enum.frequencies_by(accesses, &{&1.signature, &1.kind})
  end

  defp downgrade(project, file, strict, lenient) do
    callers = malformed_callers(project, lenient)
    target = IRHelpers.func_id_to_string({lenient.module, lenient.function, lenient.arity})

    StrictnessDowngrade.new(
      kind: downgrade_kind(strict.kind),
      module: inspect(lenient.module),
      function: lenient.function,
      arity: lenient.arity,
      variable: lenient.variable,
      parameter_index: lenient.parameter_index,
      key: lenient.key,
      file: file,
      old_line: strict.line,
      new_line: lenient.line,
      message:
        "#{strict_label(strict)} in #{target} was replaced by Map.get/2 or Map.get/3, widening the accepted input contract",
      suggestion: suggestion(target, lenient.key, callers),
      malformed_callers: callers,
      confidence: :high
    )
  end

  defp downgrade_kind(:field_access), do: :field_to_get
  defp downgrade_kind(:fetch), do: :fetch_to_get
  defp downgrade_kind(:map_pattern), do: :pattern_to_get

  defp strict_label(%{kind: :field_access, variable: variable, key: key}),
    do: "#{variable}.#{key}"

  defp strict_label(%{kind: :fetch, variable: variable, key: key}),
    do: "Map.fetch!(#{variable}, #{inspect(key)})"

  defp strict_label(%{kind: :map_pattern, key: key}), do: "required map key #{inspect(key)}"

  defp suggestion(target, key, []) do
    "Fix or normalize callers of #{target} that violate the required #{inspect(key)} key instead of weakening the consumer"
  end

  defp suggestion(target, key, callers) do
    caller_ids = callers |> Enum.map(& &1.id) |> Enum.uniq() |> Enum.sort() |> Enum.join(", ")

    "Fix or normalize #{caller_ids}, which pass map literals without required key #{inspect(key)} to #{target}"
  end

  defp malformed_callers(_project, %{parameter_index: nil}), do: []

  defp malformed_callers(project, access) do
    function_index = Query.function_index(project)

    project.nodes
    |> Map.values()
    |> Enum.filter(&call_to_target?(&1, access, function_index))
    |> Enum.flat_map(&malformed_call(&1, access, function_index))
    |> Enum.uniq_by(&{&1.id, &1.file, &1.line})
    |> Enum.sort_by(&{&1.file || "", &1.line || 0, &1.id})
  end

  defp call_to_target?(%{type: :call} = call, access, function_index) do
    caller = Map.get(function_index.node_to_function, call.id)

    call.meta[:function] == access.function and call.meta[:arity] == access.arity and
      (call.meta[:module] == access.module or
         ((is_nil(call.meta[:module]) and caller) && elem(caller, 0) == access.module))
  end

  defp call_to_target?(_node, _access, _function_index), do: false

  defp malformed_call(call, access, function_index) do
    case Enum.at(call.children, access.parameter_index) do
      %{type: :map} = argument ->
        if access.key in map_keys(argument) do
          []
        else
          [caller_summary(call, argument, access.key, function_index)]
        end

      _other ->
        []
    end
  end

  defp map_keys(map) do
    map.children
    |> Enum.flat_map(fn
      %{type: :map_field, children: [%{type: :literal, meta: %{value: key}} | _]}
      when is_atom(key) ->
        [key]

      _field ->
        []
    end)
  end

  defp caller_summary(call, argument, key, function_index) do
    caller = Map.get(function_index.node_to_function, call.id)
    span = call.source_span || argument.source_span

    %{
      id: caller && IRHelpers.func_id_to_string(caller),
      file: span && span.file,
      line: span && span.start_line,
      argument: "map literal without #{inspect(key)}"
    }
  end

  defp accesses(source) do
    with {:ok, ast} <- Sourceror.parse_string(source) do
      {:ok, ast |> module_entries(nil) |> Enum.flat_map(&module_accesses/1)}
    end
  rescue
    _error in [ArgumentError, SyntaxError, TokenMissingError] -> {:error, :invalid_source}
  end

  defp module_entries({:__block__, _meta, statements}, parent) when is_list(statements) do
    Enum.flat_map(statements, &module_entries(&1, parent))
  end

  defp module_entries({:defmodule, _meta, [name_ast, body]}, parent) do
    module = module_name(name_ast, parent)
    statements = body |> Reach.AST.keyword_value(:do) |> block_statements()
    [{module, statements} | Enum.flat_map(statements, &module_entries(&1, module))]
  end

  defp module_entries(_ast, _parent), do: []

  defp module_accesses({module, statements}) do
    statements
    |> Enum.flat_map(&function_definition(&1, module))
    |> Enum.flat_map(&function_accesses/1)
  end

  defp function_definition({kind, _meta, [head, body]}, module) when kind in [:def, :defp] do
    with {call, _guards} <- split_guards(head),
         {name, _call_meta, params} when is_atom(name) and is_list(params) <- call,
         {:ok, expression} <- Reach.AST.keyword_fetch(body, :do) do
      [
        %{
          module: module,
          name: name,
          arity: length(params),
          params: params,
          ast: {head, expression}
        }
      ]
    else
      _unsupported -> []
    end
  end

  defp function_definition(_statement, _module), do: []

  defp function_accesses(function) do
    parameter_vars = parameter_variables(function.params)
    context = Map.put(function, :parameter_vars, parameter_vars)
    parameter_patterns = parameter_pattern_accesses(function)

    {_ast, accesses} =
      Macro.prewalk(function.ast, [], fn node, accesses ->
        {node, node_accesses(node, context) ++ accesses}
      end)

    (parameter_patterns ++ Enum.reverse(accesses))
    |> Enum.uniq_by(&{&1.kind, &1.signature, &1.line})
  end

  defp parameter_variables(params) do
    params
    |> Stream.with_index()
    |> Enum.reduce(%{}, fn {parameter, index}, variables ->
      {_parameter, names} =
        Macro.prewalk(parameter, MapSet.new(), fn
          {name, _meta, context} = variable, names when is_atom(name) and is_atom(context) ->
            {variable, MapSet.put(names, name)}

          node, names ->
            {node, names}
        end)

      Enum.reduce(names, variables, &Map.put_new(&2, &1, index))
    end)
  end

  defp parameter_pattern_accesses(function) do
    function.params
    |> Enum.with_index()
    |> Enum.flat_map(fn {parameter, index} ->
      parameter
      |> direct_parameter_map_patterns()
      |> Enum.flat_map(fn {map, keys} ->
        Enum.map(keys, &access(:map_pattern, function, nil, index, &1, node_line(map)))
      end)
    end)
  end

  defp direct_parameter_map_patterns(parameter), do: collect_parameter_map_patterns(parameter, [])

  defp collect_parameter_map_patterns({:%{}, _meta, _fields} = map, patterns),
    do: [{map, map_pattern_keys(map)} | patterns]

  defp collect_parameter_map_patterns({:=, _meta, [left, right]}, patterns) do
    collect_parameter_map_patterns(left, collect_parameter_map_patterns(right, patterns))
  end

  defp collect_parameter_map_patterns(_parameter, patterns), do: patterns

  defp node_accesses(node, context) do
    field_access(node, context) ++
      map_call_access(node, context) ++ map_pattern_access(node, context)
  end

  defp field_access({{:., _dot_meta, [receiver, key]}, meta, []}, context)
       when is_atom(key) do
    if meta[:no_parens] do
      receiver_access(:field_access, receiver, key, meta[:line], context)
    else
      []
    end
  end

  defp field_access(_node, _context), do: []

  defp map_call_access(node, context) do
    case Reach.AST.call(node) do
      {Map, function, [receiver, key | _rest]} when function in [:get, :fetch!] ->
        case literal_atom(key) do
          nil -> []
          key -> receiver_access(map_call_kind(function), receiver, key, node_line(node), context)
        end

      _other ->
        []
    end
  end

  defp map_call_kind(:get), do: :map_get
  defp map_call_kind(:fetch!), do: :fetch

  defp map_pattern_access({:=, meta, [left, right]}, context) do
    pattern_match_access(left, right, meta[:line], context) ++
      pattern_match_access(right, left, meta[:line], context)
  end

  defp map_pattern_access(_node, _context), do: []

  defp pattern_match_access({:%{}, _meta, _fields} = map, receiver, line, context) do
    case variable_name(receiver) do
      nil ->
        []

      variable ->
        parameter_index = Map.get(context.parameter_vars, variable)

        Enum.map(
          map_pattern_keys(map),
          &access(:map_pattern, context, variable, parameter_index, &1, line)
        )
    end
  end

  defp pattern_match_access(_pattern, _receiver, _line, _context), do: []

  defp receiver_access(kind, receiver, key, line, context) do
    case variable_name(receiver) do
      nil ->
        []

      variable ->
        [access(kind, context, variable, Map.get(context.parameter_vars, variable), key, line)]
    end
  end

  defp access(kind, context, variable, parameter_index, key, line) do
    receiver =
      if is_integer(parameter_index),
        do: {:parameter, parameter_index},
        else: {:variable, variable}

    %{
      kind: kind,
      module: context.module,
      function: context.name,
      arity: context.arity,
      variable: variable,
      parameter_index: parameter_index,
      key: key,
      line: line,
      signature: {context.module, context.name, context.arity, receiver, key}
    }
  end

  defp map_pattern_keys({:%{}, _meta, fields}) do
    fields
    |> Enum.flat_map(fn
      {key, _value} -> List.wrap(literal_atom(key))
      _field -> []
    end)
    |> Enum.uniq()
  end

  defp literal_atom({:__block__, _meta, [atom]}) when is_atom(atom), do: atom
  defp literal_atom(atom) when is_atom(atom), do: atom
  defp literal_atom(_value), do: nil

  defp variable_name({name, _meta, context}) when is_atom(name) and is_atom(context), do: name
  defp variable_name(_value), do: nil

  defp node_line({_form, meta, _args}) when is_list(meta), do: meta[:line] || 0
  defp node_line(_node), do: 0

  defp module_name({:__aliases__, _meta, parts}, parent) when is_list(parts) do
    if parent && length(parts) == 1,
      do: Module.concat(parent, hd(parts)),
      else: Module.concat(parts)
  end

  defp module_name(atom, parent) when is_atom(atom) do
    if parent, do: Module.concat(parent, atom), else: atom
  end

  defp module_name(_ast, _parent), do: nil

  defp split_guards({:when, _meta, [head | guards]}), do: {head, guards}
  defp split_guards(head), do: {head, []}

  defp block_statements({:__block__, _meta, statements}) when is_list(statements), do: statements
  defp block_statements(nil), do: []
  defp block_statements(statement), do: [statement]

  defp line_in_old?(_line, %Range{old_count: 0}), do: false

  defp line_in_old?(line, %Range{} = range),
    do: line in range.old_start..(range.old_start + range.old_count - 1)

  defp line_in_new?(_line, %Range{new_count: 0}), do: false

  defp line_in_new?(line, %Range{} = range),
    do: line in range.new_start..(range.new_start + range.new_count - 1)

  defp elixir_file?(file), do: Path.extname(file) in [".ex", ".exs"]
end
