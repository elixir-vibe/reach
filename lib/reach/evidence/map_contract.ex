defmodule Reach.Evidence.MapContract do
  @moduledoc "Collects intra-procedural evidence for maps that behave like implicit contracts."

  defmodule Contract do
    @moduledoc false
    defstruct [:variable, :keys, :location, :reads, :updates, :confidence]
  end

  @min_keys 3
  @min_observations 2

  def collect_ast(ast) do
    ast
    |> function_bodies()
    |> Enum.flat_map(&contracts_in_scope/1)
  end

  defp function_bodies(ast) do
    {_ast, bodies} =
      Macro.prewalk(ast, [], fn
        {def_kind, _meta, [_head, block]} = node, bodies when def_kind in [:def, :defp] ->
          {node, add_function_body(block, bodies)}

        {def_kind, _meta, [{:when, _, [_head | _guards]}, block]} = node, bodies
        when def_kind in [:def, :defp] ->
          {node, add_function_body(block, bodies)}

        node, bodies ->
          {node, bodies}
      end)

    bodies
  end

  defp add_function_body([do: body], bodies), do: [body | bodies]
  defp add_function_body([{{:__block__, _meta, [:do]}, body}], bodies), do: [body | bodies]
  defp add_function_body(_block, bodies), do: bodies

  defp contracts_in_scope(ast) do
    bindings = top_level_map_bindings(ast)

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
              confidence: confidence(binding.keys, observed_keys, updates)
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
