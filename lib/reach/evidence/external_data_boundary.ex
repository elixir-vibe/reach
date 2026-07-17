defmodule Reach.Evidence.ExternalDataBoundary do
  @moduledoc "Collects decoded external values crossing storage or process boundaries."

  alias Reach.Evidence.AST
  alias Reach.Evidence.ExternalDataBoundary.Fact
  alias Reach.Source

  defmodule Origin do
    @moduledoc false
    @type t :: %__MODULE__{source: String.t(), line: pos_integer() | nil}
    @enforce_keys [:source]
    defstruct [:source, :line]
  end

  @type taint :: [Origin.t()]
  @type environment :: %{
          optional(atom() | {:reach, :state_callback}) => taint() | {atom(), non_neg_integer()}
        }

  @state_callback_key {:reach, :state_callback}
  @default_fixed_contract_min_keys 2

  @doc "Returns whether boundary evidence has enough fixed-key consumers for policy promotion."
  @spec fixed_contract?(Fact.t(), pos_integer()) :: boolean()
  def fixed_contract?(fact, min_keys \\ @default_fixed_contract_min_keys) do
    length(fact.consumer_keys) >= min_keys
  end

  @doc "Collects boundary-crossing evidence from all source files in a project."
  @spec collect_project(Reach.Project.t()) :: [Fact.t()]
  def collect_project(project) do
    plugins = Map.get(project, :plugins, [])

    project
    |> Source.project_files()
    |> Enum.flat_map(&collect_file(&1, plugins))
    |> Enum.uniq_by(&{&1.file, &1.line, &1.boundary, &1.source, &1.source_line})
    |> Enum.sort_by(&{&1.file, &1.line || 0, &1.column || 0, &1.source})
  end

  @doc false
  @spec collect_ast(Macro.t(), Path.t(), [module()]) :: [Fact.t()]
  def collect_ast(ast, file, plugins) do
    ast
    |> function_bodies()
    |> Enum.flat_map(fn %{
                          body: body,
                          state_callback: state_callback,
                          function: boundary_function,
                          consumer_profiles: consumer_profiles
                        } ->
      environment =
        if state_callback, do: %{@state_callback_key => state_callback}, else: %{}

      {facts, _taint, _environment} = analyze(body, environment, file, plugins)

      Enum.map(facts, fn fact ->
        profiles = Enum.map(fact.variables, &Map.get(consumer_profiles, &1, empty_profile()))
        keys = profiles |> Enum.flat_map(& &1.keys) |> Enum.uniq() |> Enum.sort()
        consumers = profiles |> Enum.flat_map(& &1.functions) |> Enum.uniq() |> Enum.sort()

        %{
          fact
          | boundary_function: boundary_function,
            consumer_keys: keys,
            consumer_functions: consumers
        }
      end)
    end)
  end

  defp literal_consumer_keys(ast) do
    ast
    |> AST.collect(fn node, accesses ->
      case literal_access(node) do
        nil -> accesses
        access -> [access | accesses]
      end
    end)
    |> Enum.group_by(fn {variable, _key} -> variable end, fn {_variable, key} ->
      to_string(key)
    end)
    |> Map.new(fn {variable, keys} -> {variable, keys |> Enum.uniq() |> Enum.sort()} end)
  end

  defp literal_access({{:., _, [Access, :get]}, _, [{variable, _, context}, key]})
       when is_atom(variable) and is_atom(context) and (is_atom(key) or is_binary(key)),
       do: {variable, key}

  defp literal_access(
         {{:., _, [{:__aliases__, _, [:Access]}, :get]}, _, [{variable, _, context}, key]}
       )
       when is_atom(variable) and is_atom(context) and (is_atom(key) or is_binary(key)),
       do: {variable, key}

  defp literal_access(
         {{:., _, [{:__aliases__, _, [:Map]}, function]}, _,
          [
            {variable, _, context},
            key | _rest
          ]}
       )
       when is_atom(variable) and is_atom(context) and function in [:fetch, :fetch!, :get] and
              (is_atom(key) or is_binary(key)),
       do: {variable, key}

  defp literal_access(_ast), do: nil

  defp collect_file(file, plugins) do
    with {:ok, source} <- File.read(file),
         {:ok, ast} <- Code.string_to_quoted(source, columns: true, emit_warnings: false) do
      collect_ast(ast, file, plugins)
    else
      _error -> []
    end
  end

  defp function_bodies(ast) do
    ast
    |> AST.collect(fn
      {:defmodule, _meta, [module_ast, block]}, modules when is_list(block) ->
        with {:ok, module} <- module_name(module_ast),
             {:ok, body} <- Keyword.fetch(block, :do) do
          [{module, body} | modules]
        else
          _other -> modules
        end

      _node, modules ->
        modules
    end)
    |> Enum.flat_map(&module_function_bodies/1)
  end

  defp module_function_bodies({module, body}) do
    genserver? = AST.contains?(body, &genserver_use?/1)

    functions =
      body
      |> module_statements()
      |> Enum.flat_map(fn statement ->
        case function_body(statement, module, genserver?) do
          nil -> []
          function -> [function]
        end
      end)

    consumer_profiles = consumer_profiles(functions)
    Enum.map(functions, &Map.put(&1, :consumer_profiles, consumer_profiles))
  end

  defp consumer_profiles(functions) do
    Enum.reduce(functions, %{}, fn function, profiles ->
      function.body
      |> literal_consumer_keys()
      |> Enum.reduce(profiles, &put_consumer_profile(&1, &2, function.function))
    end)
  end

  defp put_consumer_profile({variable, keys}, profiles, function) do
    Map.update(profiles, variable, %{keys: keys, functions: [function]}, fn profile ->
      %{
        keys:
          profile.keys
          |> MapSet.new()
          |> MapSet.union(MapSet.new(keys))
          |> MapSet.to_list(),
        functions: Enum.uniq([function | profile.functions])
      }
    end)
  end

  defp empty_profile, do: %{keys: [], functions: []}

  defp module_name({:__aliases__, _meta, parts}) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1), do: {:ok, Module.concat(parts)}, else: :error
  end

  defp module_name(_module_ast), do: :error

  defp module_statements({:__block__, _meta, statements}), do: statements
  defp module_statements(body), do: [body]

  defp function_body({kind, _meta, [head, block]}, module, genserver?)
       when kind in [:def, :defp] and is_list(block) do
    with {:ok, body} <- Keyword.fetch(block, :do),
         {:ok, name, arity} <- function_identity(head) do
      state_callback = if genserver? and state_callback?(name, arity), do: {name, arity}
      %{body: body, function: {module, name, arity}, state_callback: state_callback}
    else
      _other -> nil
    end
  end

  defp function_body(_node, _module, _genserver?), do: nil

  defp function_identity({:when, _meta, [head | _guards]}), do: function_identity(head)

  defp function_identity({name, _meta, nil}) when is_atom(name), do: {:ok, name, 0}

  defp function_identity({name, _meta, args}) when is_atom(name) and is_list(args),
    do: {:ok, name, length(args)}

  defp function_identity(_head), do: :error

  defp genserver_use?({:use, _meta, [{:__aliases__, _, [:GenServer]} | _args]}), do: true

  defp genserver_use?({:@, _meta, [{:behaviour, _, [{:__aliases__, _, [:GenServer]}]}]}),
    do: true

  defp genserver_use?(_ast), do: false

  defp state_callback?(:init, 1), do: true
  defp state_callback?(:handle_call, 3), do: true

  defp state_callback?(name, 2) when name in [:handle_cast, :handle_info, :handle_continue],
    do: true

  defp state_callback?(:code_change, 3), do: true
  defp state_callback?(_name, _arity), do: false

  defp analyze({:__block__, _meta, statements}, environment, file, plugins) do
    {facts, taint, environment} =
      Enum.reduce(statements, {[], [], environment}, fn statement, {facts, _taint, environment} ->
        {new_facts, taint, environment} = analyze(statement, environment, file, plugins)
        {Enum.reverse(new_facts, facts), taint, environment}
      end)

    {Enum.reverse(facts), taint, environment}
  end

  defp analyze({:=, _meta, [pattern, expression]}, environment, file, plugins) do
    {facts, taint, environment} = analyze(expression, environment, file, plugins)
    {facts, taint, bind_pattern(environment, pattern, taint)}
  end

  defp analyze({:case, _meta, [subject, clauses]}, environment, file, plugins) do
    {subject_facts, subject_taint, _environment} =
      analyze(subject, environment, file, plugins)

    case_clauses =
      case keyword_get(clauses, :do, []) do
        clauses when is_list(clauses) -> clauses
        _dynamic_clauses -> []
      end

    {clause_facts, clause_taints} =
      case_clauses
      |> Enum.map(&analyze_clause(&1, environment, subject_taint, file, plugins))
      |> Enum.unzip()

    {subject_facts ++ List.flatten(clause_facts), merge_taints(clause_taints), environment}
  end

  defp analyze({:with, _meta, arguments}, environment, file, plugins)
       when is_list(arguments) do
    qualifiers = Enum.drop(arguments, -1)
    options = List.last(arguments) || []

    {qualifier_facts, with_environment} =
      Enum.reduce(qualifiers, {[], environment}, fn qualifier, {facts, environment} ->
        case qualifier do
          {:<-, _meta, [pattern, expression]} ->
            {new_facts, taint, _environment} = analyze(expression, environment, file, plugins)
            {Enum.reverse(new_facts, facts), bind_pattern(environment, pattern, taint)}

          expression ->
            {new_facts, _taint, environment} = analyze(expression, environment, file, plugins)
            {Enum.reverse(new_facts, facts), environment}
        end
      end)

    qualifier_facts = Enum.reverse(qualifier_facts)

    {body_facts, body_taint, _environment} =
      options |> keyword_get(:do) |> analyze(with_environment, file, plugins)

    {qualifier_facts ++ body_facts, body_taint, environment}
  end

  defp analyze({kind, _meta, [condition, options]}, environment, file, plugins)
       when kind in [:if, :unless] and is_list(options) do
    {condition_facts, _condition_taint, _environment} =
      analyze(condition, environment, file, plugins)

    branches =
      [keyword_get(options, :do), keyword_get(options, :else)] |> Enum.reject(&is_nil/1)

    {branch_facts, branch_taints} =
      branches
      |> Enum.map(fn branch ->
        {facts, taint, _environment} = analyze(branch, environment, file, plugins)
        {facts, taint}
      end)
      |> Enum.unzip()

    {condition_facts ++ List.flatten(branch_facts), merge_taints(branch_taints), environment}
  end

  defp analyze({name, _meta, context}, environment, _file, _plugins)
       when is_atom(name) and is_atom(context) do
    {[], Map.get(environment, name, []), environment}
  end

  defp analyze(ast, environment, file, plugins) do
    case Reach.Plugin.external_data_source(plugins, ast) do
      source when is_binary(source) ->
        {facts, environment} = analyze_children(ast, environment, file, plugins)
        line = ast_line(ast)
        {facts, [%Origin{source: source, line: line}], environment}

      nil ->
        analyze_non_source(ast, environment, file, plugins)
    end
  end

  defp analyze_non_source(ast, environment, file, plugins) do
    children = ast_children(ast)

    {child_facts, child_taints, environment} =
      Enum.reduce(children, {[], [], environment}, fn child, {facts, taints, environment} ->
        {new_facts, taint, environment} = analyze(child, environment, file, plugins)
        {Enum.reverse(new_facts, facts), [taint | taints], environment}
      end)

    child_facts = Enum.reverse(child_facts)
    child_taints = Enum.reverse(child_taints)

    facts =
      case boundary_call(ast, environment) do
        {boundary, kind, data_index} ->
          taint = Enum.at(child_taints, data_index, [])
          data = Enum.at(children, data_index)
          child_facts ++ boundary_facts(taint, boundary, kind, ast, data, file)

        nil ->
          child_facts
      end

    {facts, output_taint(ast, child_taints), environment}
  end

  defp analyze_children(ast, environment, file, plugins) do
    {facts, environment} =
      Enum.reduce(ast_children(ast), {[], environment}, fn child, {facts, environment} ->
        {new_facts, _taint, environment} = analyze(child, environment, file, plugins)
        {Enum.reverse(new_facts, facts), environment}
      end)

    {Enum.reverse(facts), environment}
  end

  defp analyze_clause({:->, _meta, [patterns, body]}, environment, subject_taint, file, plugins) do
    environment = Enum.reduce(patterns, environment, &bind_pattern(&2, &1, subject_taint))
    {facts, taint, _environment} = analyze(body, environment, file, plugins)
    {facts, taint}
  end

  defp analyze_clause(_clause, _environment, _subject_taint, _file, _plugins), do: {[], []}

  defp bind_pattern(environment, {name, _meta, context}, taint)
       when is_atom(name) and is_atom(context) and name != :_ do
    Map.put(environment, name, taint)
  end

  defp bind_pattern(environment, pattern, taint) do
    {_pattern, environment} =
      Macro.prewalk(pattern, environment, fn
        {name, _meta, context} = node, environment
        when is_atom(name) and is_atom(context) and name != :_ ->
          {node, Map.put(environment, name, taint)}

        node, environment ->
          {node, environment}
      end)

    environment
  end

  defp merge_taints(taints) do
    taints
    |> List.flatten()
    |> Enum.uniq_by(&{&1.source, &1.line})
  end

  defp boundary_call(ast, environment) do
    case AST.call_descriptor(ast) do
      {:ok, descriptor} -> boundary(descriptor)
      :error -> state_boundary(ast, Map.get(environment, @state_callback_key))
    end
  end

  defp state_boundary(ast, callback) do
    case state_return(ast, callback) do
      nil ->
        nil

      {tag, data_index} ->
        {"GenServer.#{elem(callback, 0)}/#{elem(callback, 1)} #{tag} state return", :process,
         data_index}
    end
  end

  defp state_return(ast, callback) do
    case {callback, tuple_elements(ast)} do
      {{:init, 1}, [:ok, _state]} ->
        {:ok, 1}

      {{:code_change, 3}, [:ok, _state]} ->
        {:ok, 1}

      {{:handle_call, 3}, [:reply, _reply, _state]} ->
        {:reply, 2}

      {{:handle_call, 3}, [:noreply, _state]} ->
        {:noreply, 1}

      {{name, 2}, [:noreply, _state]}
      when name in [:handle_cast, :handle_info, :handle_continue] ->
        {:noreply, 1}

      _other ->
        nil
    end
  end

  defp tuple_elements({:{}, _meta, elements}) when is_list(elements), do: elements

  defp tuple_elements(tuple) when is_tuple(tuple) and tuple_size(tuple) == 2,
    do: Tuple.to_list(tuple)

  defp tuple_elements(_ast), do: nil

  defp boundary(%{module: :persistent_term, function: :put, arity: 2}),
    do: {":persistent_term.put/2", :storage, 1}

  defp boundary(%{module: :ets, function: function, arity: 2})
       when function in [:insert, :insert_new],
       do: {":ets.#{function}/2", :storage, 1}

  defp boundary(%{module: module, function: :put, arity: 2})
       when module in [Process, :erlang],
       do: {boundary_label(module, :put, 2), :storage, 1}

  defp boundary(%{module: GenServer, function: function, arity: arity})
       when function in [:call, :cast, :start, :start_link] and arity in [2, 3],
       do: {boundary_label(GenServer, function, arity), :process, 1}

  defp boundary(%{module: nil, function: :send, arity: 2}),
    do: {"send/2", :process, 1}

  defp boundary(%{module: module, function: function, arity: arity})
       when module in [Process, :erlang] and function in [:send, :send_after] and arity in [2, 3],
       do: {boundary_label(module, function, arity), :process, 1}

  defp boundary(_descriptor), do: nil

  defp boundary_label(module, function, arity) when is_atom(module) do
    "#{inspect(module)}.#{function}/#{arity}"
  end

  defp boundary_facts(taint, boundary, kind, ast, data, file) do
    line = ast_line(ast)
    column = ast_column(ast)
    variables = boundary_variables(data)

    Enum.map(taint, fn origin ->
      %Fact{
        source: origin.source,
        source_line: origin.line,
        boundary: boundary,
        boundary_kind: kind,
        file: file,
        line: line,
        column: column,
        variables: variables
      }
    end)
  end

  defp boundary_variables(nil), do: []

  defp boundary_variables(ast) do
    {_ast, variables} =
      Macro.prewalk(ast, [], fn
        {name, _meta, context} = node, variables
        when is_atom(name) and is_atom(context) and name != :_ ->
          {node, [name | variables]}

        node, variables ->
          {node, variables}
      end)

    variables |> Enum.uniq() |> Enum.sort()
  end

  defp output_taint(ast, child_taints) when is_list(ast), do: merge_taints(child_taints)
  defp output_taint({:{}, _meta, _elements}, child_taints), do: merge_taints(child_taints)

  defp output_taint(ast, child_taints) when is_tuple(ast) and tuple_size(ast) == 2,
    do: merge_taints(child_taints)

  defp output_taint(_ast, _child_taints), do: []

  defp keyword_get(keyword, key, default \\ nil)

  defp keyword_get(keyword, key, default) when is_list(keyword),
    do: Keyword.get(keyword, key, default)

  defp keyword_get(_keyword, _key, default), do: default

  defp ast_children({_form, _meta, args}) when is_list(args), do: args

  defp ast_children(tuple) when is_tuple(tuple) and tuple_size(tuple) == 2,
    do: Tuple.to_list(tuple)

  defp ast_children(list) when is_list(list), do: list
  defp ast_children(_ast), do: []

  defp ast_line({_form, meta, _args}) when is_list(meta), do: meta[:line]

  defp ast_line(tuple) when is_tuple(tuple) and tuple_size(tuple) == 2 do
    tuple |> Tuple.to_list() |> Enum.find_value(&ast_line/1)
  end

  defp ast_line(_ast), do: nil

  defp ast_column({_form, meta, _args}) when is_list(meta), do: meta[:column]

  defp ast_column(tuple) when is_tuple(tuple) and tuple_size(tuple) == 2 do
    tuple |> Tuple.to_list() |> Enum.find_value(&ast_column/1)
  end

  defp ast_column(_ast), do: nil
end
