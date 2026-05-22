defmodule Reach.Evidence.StandardLibraryBypass.Map do
  @moduledoc "Collects Map standard-library bypass evidence."

  alias Reach.Evidence.AST
  alias Reach.Evidence.StandardLibraryBypass

  def collect_ast(ast) do
    AST.collect(ast, &collect_node/2)
  end

  def kinds, do: [:manual_map_update, :manual_map_update_bang]

  defp collect_node(node, acc) do
    case {map_update_shape(node), map_update_bang_shape(node)} do
      {{:ok, meta}, _update_bang} ->
        evidence(
          acc,
          :manual_map_update,
          "Map.has_key? plus paired Map.put branches reimplements Map.update/4",
          "Map.update/4",
          meta
        )

      {_update, {:ok, meta}} ->
        evidence(
          acc,
          :manual_map_update_bang,
          "Map.fetch! followed by Map.put on the same key reimplements Map.update!/3",
          "Map.update!/3",
          meta
        )

      _ ->
        acc
    end
  end

  defp map_update_shape({:if, meta, [condition, [do: do_branch, else: else_branch]]}) do
    with {:ok, map, key} <- map_has_key_call(condition),
         true <- map_put_call?(do_branch, map, key),
         true <- map_put_call?(else_branch, map, key) do
      {:ok, meta}
    else
      _other -> :error
    end
  end

  defp map_update_shape(_node), do: :error

  defp map_has_key_call({{:., _, [{:__aliases__, _, [:Map]}, :has_key?]}, _, [map, key]}),
    do: {:ok, map, key}

  defp map_has_key_call(_node), do: :error

  defp map_put_call?(
         {{:., _, [{:__aliases__, _, [:Map]}, :put]}, _, [map, key, _value]},
         expected_map,
         expected_key
       ),
       do: AST.same_ast?(map, expected_map) and AST.same_ast?(key, expected_key)

  defp map_put_call?(_node, _expected_map, _expected_key), do: false

  defp map_update_bang_shape({:__block__, meta, [assignment, put_call]}) do
    with {:ok, value_var, map, key, assignment_meta} <- fetch_bang_assignment(assignment),
         true <- update_bang_put_call?(put_call, map, key, value_var) do
      {:ok, line_meta(assignment_meta, meta)}
    else
      _other -> :error
    end
  end

  defp map_update_bang_shape(
         {{:., meta, [{:__aliases__, _, [:Map]}, :put]}, _, [map, key, value]}
       ) do
    if fetch_bang_value_for?(value, map, key), do: {:ok, meta}, else: :error
  end

  defp map_update_bang_shape(_node), do: :error

  defp fetch_bang_assignment(
         {:=, meta, [value_var, {{:., _, [{:__aliases__, _, [:Map]}, :fetch!]}, _, [map, key]}]}
       ),
       do: {:ok, value_var, map, key, meta}

  defp fetch_bang_assignment(_node), do: :error

  defp update_bang_put_call?(
         {{:., _, [{:__aliases__, _, [:Map]}, :put]}, _, [map, key, value]},
         expected_map,
         expected_key,
         value_var
       ) do
    AST.same_ast?(map, expected_map) and AST.same_ast?(key, expected_key) and
      AST.references?(value, value_var)
  end

  defp update_bang_put_call?(_node, _expected_map, _expected_key, _value_var), do: false

  defp fetch_bang_value_for?(node, expected_map, expected_key) do
    AST.contains?(node, fn
      {{:., _, [{:__aliases__, _, [:Map]}, :fetch!]}, _, [map, key]} ->
        AST.same_ast?(map, expected_map) and AST.same_ast?(key, expected_key)

      _child ->
        false
    end)
  end

  defp line_meta(preferred, fallback) do
    if Keyword.get(preferred, :line), do: preferred, else: fallback
  end

  defp evidence(acc, kind, message, replacement, meta) do
    [StandardLibraryBypass.fact(kind, message, replacement, meta) | acc]
  end
end
