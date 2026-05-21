defmodule Reach.Evidence.MapContract do
  @moduledoc "Collects evidence for maps that behave like implicit contracts."

  defmodule Contract do
    @moduledoc false
    defstruct [:variable, :keys, :location, :reads, :updates, :confidence, :source, :producer]
  end

  @min_keys 3
  @min_observations 2

  def family, do: :map_contract
  def kinds, do: [:implicit_map_contract]

  def collect_ast(ast) do
    definitions = function_definitions(ast)
    local_contracts = definitions |> Enum.map(& &1.body) |> Enum.flat_map(&contracts_in_scope/1)
    return_contracts = return_flow_contracts(definitions)

    local_contracts ++ return_contracts
  end

  defp function_definitions(ast) do
    {_ast, definitions} =
      Macro.prewalk(ast, [], fn
        {def_kind, _meta, [head, block]} = node, definitions when def_kind in [:def, :defp] ->
          {node, add_function_definition(head, block, definitions)}

        node, definitions ->
          {node, definitions}
      end)

    Enum.reverse(definitions)
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

  defp contracts_in_scope(ast) do
    ast
    |> top_level_map_bindings()
    |> contracts_from_bindings(ast, :local)
  end

  defp return_flow_contracts(definitions) do
    return_shapes = return_shapes(definitions)

    definitions
    |> Enum.flat_map(fn definition ->
      definition.body
      |> top_level_return_bindings(return_shapes)
      |> contracts_from_bindings(definition.body, :return)
    end)
  end

  defp return_shapes(definitions) do
    Map.new(definitions, fn definition ->
      {{definition.name, definition.arity}, returned_shape(definition)}
    end)
    |> Enum.reject(fn {_mfa, shape} -> is_nil(shape) end)
    |> Map.new()
  end

  defp returned_shape(%{body: body, meta: meta}) do
    case last_expression(body) |> map_literal_keys() do
      keys when length(keys) >= @min_keys -> %{keys: keys, meta: meta}
      _keys -> nil
    end
  end

  defp last_expression({:__block__, _meta, statements}) when is_list(statements),
    do: List.last(statements)

  defp last_expression(body), do: body

  defp contracts_from_bindings(bindings, ast, source) do
    if bindings == %{} do
      []
    else
      observations = map_observations(ast, bindings)

      bindings
      |> Enum.flat_map(fn {variable, binding} ->
        reads = observations |> Map.get(variable, []) |> Enum.filter(&(&1.kind == :read))
        updates = observations |> Map.get(variable, []) |> Enum.filter(&(&1.kind == :update))
        observed_keys = observations |> Map.get(variable, []) |> Enum.map(& &1.key) |> Enum.uniq()

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
      end)
    end
  end

  defp top_level_map_bindings({:__block__, _meta, statements}) do
    Enum.reduce(statements, %{}, &put_map_binding/2)
  end

  defp top_level_map_bindings(statement), do: put_map_binding(statement, %{})

  defp put_map_binding({:=, meta, [{var, _, context}, rhs]}, bindings)
       when is_atom(var) and is_atom(context) do
    case map_literal_keys(rhs) do
      keys when length(keys) >= @min_keys -> Map.put(bindings, var, %{keys: keys, meta: meta})
      _keys -> bindings
    end
  end

  defp put_map_binding(_statement, bindings), do: bindings

  defp top_level_return_bindings({:__block__, _meta, statements}, return_shapes) do
    Enum.reduce(statements, %{}, &put_return_binding(&1, &2, return_shapes))
  end

  defp top_level_return_bindings(statement, return_shapes),
    do: put_return_binding(statement, %{}, return_shapes)

  defp put_return_binding({:=, meta, [{var, _, context}, rhs]}, bindings, return_shapes)
       when is_atom(var) and is_atom(context) do
    with {:ok, producer} <- local_call(rhs),
         %{keys: keys} <- Map.get(return_shapes, producer) do
      Map.put(bindings, var, %{keys: keys, meta: meta, producer: producer})
    else
      _other -> bindings
    end
  end

  defp put_return_binding(_statement, bindings, _return_shapes), do: bindings

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

  defp map_observations(ast, bindings) do
    {_ast, observations} =
      Macro.prewalk(ast, %{}, fn node, observations ->
        {node, record_observation(node, bindings, observations)}
      end)

    observations
  end

  defp record_observation(node, bindings, observations) do
    case map_observation(node) do
      {:ok, variable, key, kind, meta} when is_map_key(bindings, variable) ->
        if key in bindings[variable].keys do
          observation = %{key: key, kind: kind, meta: meta}
          Map.update(observations, variable, [observation], &[observation | &1])
        else
          observations
        end

      _other ->
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
