defmodule Reach.Evidence.StandardLibraryBypass.Map do
  @moduledoc "Collects Map standard-library bypass evidence."

  alias Reach.Evidence.StandardLibraryBypass.Evidence

  def kinds, do: [:manual_map_update, :manual_map_update_bang]

  def collect_node(node, acc) do
    case {map_update_shape(node), map_update_bang_shape(node)} do
      {{:ok, meta}, _update_bang} ->
        evidence(
          acc,
          :manual_map_update,
          "Map.get plus paired Map.put branches reimplements Map.update/4",
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

  defp map_update_shape({:case, meta, [get_call, [do: clauses]]}) when is_list(clauses) do
    with {:ok, map, key} <- map_get_call(get_call),
         true <- paired_map_put_branches?(clauses, map, key) do
      {:ok, meta}
    else
      _other -> :error
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

  defp paired_map_put_branches?([left, right], map, key) do
    Enum.all?([left, right], fn
      {:->, _meta, [_patterns, body]} -> map_put_call?(body, map, key)
      _clause -> false
    end)
  end

  defp paired_map_put_branches?(_clauses, _map, _key), do: false

  defp map_get_call({{:., _, [{:__aliases__, _, [:Map]}, :get]}, _, [map, key | _]}),
    do: {:ok, map, key}

  defp map_get_call(_node), do: :error

  defp map_has_key_call({{:., _, [{:__aliases__, _, [:Map]}, :has_key?]}, _, [map, key]}),
    do: {:ok, map, key}

  defp map_has_key_call(_node), do: :error

  defp map_put_call?(
         {{:., _, [{:__aliases__, _, [:Map]}, :put]}, _, [map, key, _value]},
         expected_map,
         expected_key
       ),
       do: same_ast?(map, expected_map) and same_ast?(key, expected_key)

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
    same_ast?(map, expected_map) and same_ast?(key, expected_key) and
      references_ast?(value, value_var)
  end

  defp update_bang_put_call?(_node, _expected_map, _expected_key, _value_var), do: false

  defp fetch_bang_value_for?(node, expected_map, expected_key) do
    {_node, found?} =
      Macro.prewalk(node, false, fn
        {{:., _, [{:__aliases__, _, [:Map]}, :fetch!]}, _, [map, key]} = child, _found? ->
          {child, same_ast?(map, expected_map) and same_ast?(key, expected_key)}

        child, found? ->
          {child, found?}
      end)

    found?
  end

  defp references_ast?(node, expected) do
    {_node, found?} =
      Macro.prewalk(node, false, fn child, found? ->
        {child, found? or same_ast?(child, expected)}
      end)

    found?
  end

  defp same_ast?(left, right), do: Macro.to_string(left) == Macro.to_string(right)

  defp line_meta(preferred, fallback) do
    if Keyword.get(preferred, :line), do: preferred, else: fallback
  end

  defp evidence(acc, kind, message, replacement, meta) do
    [
      %Evidence{
        kind: kind,
        message: message,
        replacement: replacement,
        meta: meta,
        confidence: :high
      }
      | acc
    ]
  end
end
