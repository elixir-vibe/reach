defmodule Reach.Evidence.MapContract do
  @moduledoc "Collects evidence for maps that behave like implicit contracts."

  alias Reach.Evidence.AST

  defmodule Contract do
    @moduledoc false
    defstruct [:variable, :keys, :location, :reads, :updates, :confidence, :source, :producer]
  end

  @min_keys 3
  @min_observations 2

  def family, do: :map_contract
  def kinds, do: [:implicit_map_contract]

  def collect_ast(ast) do
    definitions = collect_function_definitions(ast)

    collect_local_contracts(definitions) ++ collect_return_contracts(definitions)
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

  defp returned_shape(%{body: body, meta: meta}) do
    case body |> last_expression() |> map_literal_keys() do
      keys when length(keys) >= @min_keys -> %{keys: keys, meta: meta}
      _keys -> nil
    end
  end

  defp last_expression({:__block__, _meta, statements}) when is_list(statements),
    do: List.last(statements)

  defp last_expression(body), do: body

  defp collect_literal_map_bindings({:__block__, _meta, statements}) do
    Enum.reduce(statements, %{}, &put_literal_map_binding/2)
  end

  defp collect_literal_map_bindings(statement), do: put_literal_map_binding(statement, %{})

  defp put_literal_map_binding({:=, meta, [{var, _, context}, rhs]}, bindings)
       when is_atom(var) and is_atom(context) do
    case map_literal_keys(rhs) do
      keys when length(keys) >= @min_keys -> Map.put(bindings, var, %{keys: keys, meta: meta})
      _keys -> bindings
    end
  end

  defp put_literal_map_binding(_statement, bindings), do: bindings

  defp collect_return_value_bindings({:__block__, _meta, statements}, return_shapes) do
    Enum.reduce(statements, %{}, &put_return_value_binding(&1, &2, return_shapes))
  end

  defp collect_return_value_bindings(statement, return_shapes),
    do: put_return_value_binding(statement, %{}, return_shapes)

  defp put_return_value_binding({:=, meta, [{var, _, context}, rhs]}, bindings, return_shapes)
       when is_atom(var) and is_atom(context) do
    with {:ok, producer} <- local_call(rhs),
         %{keys: keys} <- Map.get(return_shapes, producer) do
      Map.put(bindings, var, %{keys: keys, meta: meta, producer: producer})
    else
      _other -> bindings
    end
  end

  defp put_return_value_binding(_statement, bindings, _return_shapes), do: bindings

  defp local_call({name, _meta, args}) when is_atom(name) and is_list(args),
    do: {:ok, {name, length(args)}}

  defp local_call(_node), do: :error

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
    observed_keys = observations |> Enum.map(& &1.key) |> Enum.uniq()

    if length(observed_keys) >= @min_observations do
      [
        %Contract{
          variable: variable,
          keys: binding.keys,
          location: location(binding.meta),
          reads: Enum.map(reads, &observation_location/1),
          updates: Enum.map(updates, &observation_location/1),
          confidence: confidence(binding.keys, observed_keys, updates),
          source: source,
          producer: Map.get(binding, :producer)
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
        observations
    end
  end

  defp record_known_key_observation(observations, variable, binding, key, kind, meta) do
    if key in binding.keys do
      observation = %{key: key, kind: kind, meta: meta}
      Map.update(observations, variable, [observation], &[observation | &1])
    else
      observations
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

  defp confidence(keys, observed_keys, updates) do
    coverage = length(observed_keys) / max(length(keys), 1)

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
