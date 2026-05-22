defmodule Reach.Evidence.MapContract do
  @moduledoc "Collects evidence for maps that behave like implicit contracts."

  alias Reach.Evidence.AST

  defmodule Contract do
    @moduledoc false
    defstruct [
      :variable,
      :keys,
      :location,
      :reads,
      :updates,
      :confidence,
      :source,
      :producer,
      :role,
      :key_coverage,
      :observed_keys,
      :unused_keys,
      :read_count,
      :mutation_count,
      :escaped?,
      :escapes,
      :consumer
    ]
  end

  @min_keys 3
  @min_observations 2
  @assigns_names [:assigns]
  @accumulator_names [:acc, :cat, :count, :counts, :stats]
  @external_payload_names [:body, :json, :metadata, :payload, :request, :response]
  @options_names [:config, :opts, :options]
  @non_call_forms [:., :%, :{}, :__aliases__, :__block__, :=, :->, :def, :defp, :fn, :|>]

  def family, do: :map_contract
  def kinds, do: [:implicit_map_contract]

  def collect_ast(ast, opts \\ []) do
    plugins = Keyword.get(opts, :plugins, [])
    context = Keyword.get(opts, :context, %{})

    ast
    |> collect_function_definitions()
    |> collect_ast_contracts()
    |> refine_contracts(plugins, context)
  end

  def collect_project(project, opts \\ []) do
    plugins = Keyword.get(opts, :plugins, project_plugins(project))

    files =
      project
      |> project_source_files()
      |> Enum.map(&source_file_ast/1)
      |> Enum.filter(&match?({:ok, _file, _ast}, &1))

    definitions_by_file =
      Map.new(files, fn {:ok, file, ast} -> {file, collect_module_definitions(ast)} end)

    return_shapes =
      definitions_by_file
      |> Map.values()
      |> List.flatten()
      |> collect_module_return_shapes()

    Enum.flat_map(files, fn {:ok, file, ast} ->
      contracts =
        collect_file_project_contracts(
          file,
          ast,
          Map.fetch!(definitions_by_file, file),
          return_shapes
        )

      refine_contracts(contracts, plugins, %{file: file, project: project})
    end)
  end

  defp collect_ast_contracts(definitions) do
    collect_local_contracts(definitions) ++ collect_return_contracts(definitions)
  end

  defp refine_contracts(contracts, [], _context), do: contracts

  defp refine_contracts(contracts, plugins, context) do
    Enum.map(contracts, &Reach.Plugin.refine_evidence(plugins, &1, context))
  end

  defp project_plugins(project) when is_map(project), do: Map.get(project, :plugins, [])
  defp project_plugins(_project), do: []

  defp project_source_files(project) do
    project.nodes
    |> Map.values()
    |> Enum.flat_map(fn node ->
      case node.source_span do
        %{file: file} when is_binary(file) -> [file]
        _span -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.reject(&dependency_source_file?/1)
    |> Enum.sort()
  end

  defp dependency_source_file?(file) do
    String.contains?(file, "/deps/") or String.contains?(file, "/_build/")
  end

  defp source_file_ast(file) do
    with {:ok, source} <- File.read(file),
         {:ok, ast} <- Code.string_to_quoted(source, emit_warnings: false) do
      {:ok, file, ast}
    end
  end

  defp collect_file_project_contracts(file, ast, module_definitions, return_shapes) do
    local_contracts = ast |> collect_function_definitions() |> collect_ast_contracts()

    local_contracts
    |> Enum.map(&Map.put(&1, :file, file))
    |> Kernel.++(collect_cross_function_contracts(module_definitions, return_shapes, file))
  end

  defp collect_function_definitions(ast) do
    AST.collect(ast, fn
      {def_kind, _meta, [head, block]}, definitions when def_kind in [:def, :defp] ->
        add_function_definition(head, block, definitions)

      _node, definitions ->
        definitions
    end)
  end

  defp add_function_definition({:when, _meta, [head | _guards]}, block, definitions),
    do: add_function_definition(head, block, definitions)

  defp add_function_definition({name, meta, args}, block, definitions)
       when is_atom(name) and is_list(args) do
    case function_body(block) do
      nil -> definitions
      body -> [%{name: name, arity: length(args), meta: meta, body: body} | definitions]
    end
  end

  defp add_function_definition(_head, _block, definitions), do: definitions

  defp collect_module_definitions(ast) do
    AST.collect(ast, fn
      {:defmodule, _meta, [module_ast, block]}, modules ->
        case module_name(module_ast) do
          {:ok, module} -> collect_module_functions(module, block) ++ modules
          :error -> modules
        end

      _node, modules ->
        modules
    end)
  end

  defp collect_module_functions(module, block) do
    block
    |> function_body()
    |> case do
      nil -> []
      body -> Enum.map(collect_function_definitions(body), &Map.put(&1, :module, module))
    end
  end

  defp module_name({:__aliases__, _meta, parts}) when is_list(parts),
    do: {:ok, Module.concat(parts)}

  defp module_name(_node), do: :error

  defp collect_module_return_shapes(definitions) do
    definitions
    |> Map.new(fn definition ->
      {{definition.module, definition.name, definition.arity}, returned_shape(definition)}
    end)
    |> Enum.reject(fn {_mfa, shape} -> is_nil(shape) end)
    |> Map.new()
  end

  defp function_body(do: body), do: body
  defp function_body([{{:__block__, _meta, [:do]}, body}]), do: body
  defp function_body(_block), do: nil

  defp collect_local_contracts(definitions) do
    Enum.flat_map(definitions, fn definition ->
      definition.body
      |> collect_literal_map_bindings()
      |> build_contracts(definition.body, :local)
    end)
  end

  defp collect_return_contracts(definitions) do
    return_shapes = collect_return_shapes(definitions)

    Enum.flat_map(definitions, fn definition ->
      definition.body
      |> collect_return_value_bindings(return_shapes)
      |> build_contracts(definition.body, :return)
    end)
  end

  defp collect_return_shapes(definitions) do
    definitions
    |> Map.new(fn definition ->
      {{definition.name, definition.arity}, returned_shape(definition)}
    end)
    |> Enum.reject(fn {_mfa, shape} -> is_nil(shape) end)
    |> Map.new()
  end

  defp returned_shape(%{body: {:__block__, _meta, statements}, meta: meta})
       when is_list(statements) do
    bindings = collect_literal_map_bindings({:__block__, [], statements})
    returned_expression_shape(List.last(statements), bindings, meta)
  end

  defp returned_shape(%{body: body, meta: meta}) do
    returned_expression_shape(body, %{}, meta)
  end

  defp returned_expression_shape(expression, bindings, fallback_meta) do
    keys = map_literal_keys(expression)

    cond do
      length(keys) >= @min_keys ->
        %{keys: keys, meta: fallback_meta}

      match?({:ok, _variable}, variable_name(expression)) ->
        returned_variable_shape(expression, bindings)

      true ->
        nil
    end
  end

  defp returned_variable_shape(expression, bindings) do
    {:ok, variable} = variable_name(expression)
    Map.get(bindings, variable)
  end

  defp collect_literal_map_bindings({:__block__, _meta, statements}) do
    Enum.reduce(statements, %{}, &put_literal_map_binding/2)
  end

  defp collect_literal_map_bindings(statement), do: put_literal_map_binding(statement, %{})

  defp put_alias_binding(bindings, var, rhs, meta) do
    {:ok, source_var} = variable_name(rhs)

    if Map.has_key?(bindings, source_var),
      do: Map.put(bindings, var, %{bindings[source_var] | meta: meta}),
      else: bindings
  end

  defp put_literal_map_binding({:=, meta, [{var, _, context}, rhs]}, bindings)
       when is_atom(var) and is_atom(context) do
    keys = map_literal_keys(rhs)

    cond do
      length(keys) >= @min_keys ->
        Map.put(bindings, var, %{keys: keys, meta: meta})

      match?({:ok, _source_var}, variable_name(rhs)) ->
        put_alias_binding(bindings, var, rhs, meta)

      true ->
        bindings
    end
  end

  defp put_literal_map_binding(_statement, bindings), do: bindings

  defp collect_return_value_bindings({:__block__, _meta, statements}, return_shapes) do
    Enum.reduce(statements, %{}, &put_return_value_binding(&1, &2, return_shapes))
  end

  defp collect_return_value_bindings(statement, return_shapes),
    do: put_return_value_binding(statement, %{}, return_shapes)

  defp collect_cross_function_contracts(definitions, return_shapes, file) do
    Enum.flat_map(definitions, fn definition ->
      definition.body
      |> collect_cross_function_bindings(return_shapes)
      |> build_contracts(definition.body, :cross_file_return)
      |> Enum.map(fn contract ->
        contract
        |> Map.put(:file, file)
        |> Map.put(:consumer, {definition.module, definition.name, definition.arity})
      end)
    end)
  end

  defp collect_cross_function_bindings({:__block__, _meta, statements}, return_shapes) do
    Enum.reduce(statements, %{}, &put_cross_function_binding(&1, &2, return_shapes))
  end

  defp collect_cross_function_bindings(statement, return_shapes),
    do: put_cross_function_binding(statement, %{}, return_shapes)

  defp put_cross_function_binding({:=, meta, [{var, _, context}, rhs]}, bindings, return_shapes)
       when is_atom(var) and is_atom(context) do
    cond do
      match?({:ok, _producer}, remote_call(rhs)) ->
        with {:ok, producer} <- remote_call(rhs),
             %{keys: keys} <- Map.get(return_shapes, producer) do
          Map.put(bindings, var, %{keys: keys, meta: meta, producer: producer})
        else
          _other -> bindings
        end

      match?({:ok, _source_var}, variable_name(rhs)) ->
        put_existing_alias_binding(bindings, var, rhs, meta)

      true ->
        bindings
    end
  end

  defp put_cross_function_binding(_statement, bindings, _return_shapes), do: bindings

  defp put_return_value_binding({:=, meta, [{var, _, context}, rhs]}, bindings, return_shapes)
       when is_atom(var) and is_atom(context) do
    cond do
      match?({:ok, _producer}, local_call(rhs)) ->
        with {:ok, producer} <- local_call(rhs),
             %{keys: keys} <- Map.get(return_shapes, producer) do
          Map.put(bindings, var, %{keys: keys, meta: meta, producer: producer})
        else
          _other -> bindings
        end

      match?({:ok, _source_var}, variable_name(rhs)) ->
        put_existing_alias_binding(bindings, var, rhs, meta)

      true ->
        bindings
    end
  end

  defp put_return_value_binding(_statement, bindings, _return_shapes), do: bindings

  defp put_existing_alias_binding(bindings, var, rhs, meta) do
    {:ok, source_var} = variable_name(rhs)

    if Map.has_key?(bindings, source_var),
      do: Map.put(bindings, var, %{bindings[source_var] | meta: meta}),
      else: bindings
  end

  defp local_call({name, _meta, args}) when is_atom(name) and is_list(args),
    do: {:ok, {name, length(args)}}

  defp local_call(_node), do: :error

  defp remote_call({{:., _meta, [module_ast, function]}, _call_meta, args})
       when is_atom(function) and is_list(args) do
    case module_name(module_ast) do
      {:ok, module} -> {:ok, {module, function, length(args)}}
      :error -> :error
    end
  end

  defp remote_call(_node), do: :error

  defp variable_name({var, _meta, context}) when is_atom(var) and is_atom(context), do: {:ok, var}
  defp variable_name(_node), do: :error

  defp map_literal_keys({:%{}, _meta, fields}) do
    fields
    |> Enum.flat_map(fn
      {key, _value} when is_atom(key) -> [key]
      {key, _value} when is_binary(key) -> [key]
      _field -> []
    end)
    |> Enum.sort()
  end

  defp map_literal_keys(_node), do: []

  defp build_contracts(bindings, ast, source) do
    if bindings == %{} do
      []
    else
      observations = collect_map_observations(ast, bindings)

      bindings
      |> Enum.flat_map(fn {variable, binding} ->
        build_contract(variable, binding, Map.get(observations, variable, []), source)
      end)
    end
  end

  defp build_contract(variable, binding, observations, source) do
    reads = Enum.filter(observations, &(&1.kind == :read))
    updates = Enum.filter(observations, &(&1.kind == :update))
    escapes = Enum.filter(observations, &(&1.kind == :escape))

    observed_keys =
      observations
      |> Enum.flat_map(fn
        %{key: nil} -> []
        %{key: key} -> [key]
      end)
      |> Enum.uniq()
      |> Enum.sort()

    unused_keys = binding.keys -- observed_keys
    key_coverage = length(observed_keys) / max(length(binding.keys), 1)
    role = classify_role(variable, source)

    if length(observed_keys) >= @min_observations do
      [
        %Contract{
          variable: variable,
          keys: binding.keys,
          location: location(binding.meta),
          reads: Enum.map(reads, &observation_location/1),
          updates: Enum.map(updates, &observation_location/1),
          confidence: confidence(key_coverage, updates),
          source: source,
          producer: Map.get(binding, :producer),
          role: role,
          key_coverage: key_coverage,
          observed_keys: observed_keys,
          unused_keys: unused_keys,
          read_count: length(reads),
          mutation_count: length(updates),
          escaped?: escapes != [],
          escapes: Enum.map(escapes, & &1.call)
        }
      ]
    else
      []
    end
  end

  defp collect_map_observations(ast, bindings) do
    AST.reduce(ast, %{}, &record_observation(&1, bindings, &2))
  end

  defp record_observation(node, bindings, observations) do
    case map_observation(node) do
      {:ok, variable, key, kind, meta} when is_map_key(bindings, variable) ->
        record_known_key_observation(observations, variable, bindings[variable], key, kind, meta)

      _other ->
        record_escape_observation(node, bindings, observations)
    end
  end

  defp record_known_key_observation(observations, variable, binding, key, kind, meta) do
    if key in binding.keys do
      record_observation_for_variable(observations, variable, %{key: key, kind: kind, meta: meta})
    else
      observations
    end
  end

  defp record_escape_observation(node, bindings, observations) do
    case call_args(node) do
      {:ok, meta, args} ->
        call = call_descriptor(node, meta)

        args
        |> Enum.flat_map(&escaped_variables(&1, bindings))
        |> Enum.reduce(observations, fn variable, observations ->
          record_observation_for_variable(observations, variable, %{
            key: nil,
            kind: :escape,
            meta: meta,
            call: call
          })
        end)

      :error ->
        observations
    end
  end

  defp record_observation_for_variable(observations, variable, observation) do
    Map.update(observations, variable, [observation], &[observation | &1])
  end

  defp call_args({name, meta, args})
       when is_atom(name) and is_list(args) and name not in @non_call_forms,
       do: {:ok, meta, args}

  defp call_args({{:., meta, [_target, _function]}, _call_meta, args}) when is_list(args),
    do: {:ok, meta, args}

  defp call_args(_node), do: :error

  defp call_descriptor(node, fallback_meta) do
    case AST.call_descriptor(node) do
      {:ok, descriptor} ->
        descriptor

      :error ->
        %{
          module: nil,
          function: nil,
          arity: nil,
          line: fallback_meta[:line],
          column: fallback_meta[:column]
        }
    end
  end

  defp escaped_variables(arg, bindings) do
    case variable_name(arg) do
      {:ok, variable} when is_map_key(bindings, variable) -> [variable]
      _other -> []
    end
  end

  defp map_observation({{:., meta, [{var, _, context}, key]}, _, []})
       when is_atom(var) and is_atom(context) and is_atom(key),
       do: {:ok, var, key, :read, meta}

  defp map_observation(
         {{:., meta, [{:__aliases__, _, [:Map]}, :get]}, _, [{var, _, context}, key | _]}
       )
       when is_atom(var) and is_atom(context) and (is_atom(key) or is_binary(key)),
       do: {:ok, var, key, :read, meta}

  defp map_observation(
         {{:., meta, [{:__aliases__, _, [:Map]}, :fetch]}, _, [{var, _, context}, key | _]}
       )
       when is_atom(var) and is_atom(context) and (is_atom(key) or is_binary(key)),
       do: {:ok, var, key, :read, meta}

  defp map_observation(
         {{:., meta, [{:__aliases__, _, [:Map]}, :put]}, _, [{var, _, context}, key | _]}
       )
       when is_atom(var) and is_atom(context) and (is_atom(key) or is_binary(key)),
       do: {:ok, var, key, :update, meta}

  defp map_observation({:%{}, meta, [{:|, _, [{var, _, context}, fields]}]})
       when is_atom(var) and is_atom(context) and is_list(fields) do
    case fields do
      [{key, _value} | _] when is_atom(key) or is_binary(key) -> {:ok, var, key, :update, meta}
      _fields -> :error
    end
  end

  defp map_observation(_node), do: :error

  defp classify_role(variable, _source) when variable in @assigns_names, do: :assigns
  defp classify_role(variable, _source) when variable in @accumulator_names, do: :accumulator

  defp classify_role(variable, _source) when variable in @external_payload_names,
    do: :external_payload

  defp classify_role(variable, _source) when variable in @options_names, do: :options
  defp classify_role(_variable, source) when source in [:return, :cross_file_return], do: :domain
  defp classify_role(_variable, _source), do: :unknown

  defp confidence(coverage, updates) do
    cond do
      updates != [] and coverage >= 0.75 -> :high
      coverage >= 0.5 -> :medium
      true -> :low
    end
  end

  defp observation_location(%{key: key, kind: kind, meta: meta}) do
    meta |> location() |> Map.merge(%{key: key, kind: kind})
  end

  defp location(meta), do: %{line: meta[:line], column: meta[:column]}
end
