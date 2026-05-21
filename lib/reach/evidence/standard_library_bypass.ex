defmodule Reach.Evidence.StandardLibraryBypass do
  @moduledoc "Collects evidence of ad-hoc code that bypasses standard library helpers."

  defmodule Evidence do
    @moduledoc false
    defstruct [:kind, :message, :replacement, :meta, :confidence]
  end

  @path_names ~w(path filepath file_path filename file dir directory source dest destination)a
  @uri_names ~w(url uri href endpoint query query_string qs)a

  def collect_ast(ast) do
    {_ast, evidence} =
      Macro.prewalk(ast, [], fn node, acc ->
        {node, collect_node(node, acc)}
      end)

    Enum.reverse(evidence)
  end

  defp collect_node({:|>, meta, [left, right]} = node, acc) do
    acc = collect_pipe_node(left, right, meta, acc)
    collect_direct(node, acc)
  end

  defp collect_node(node, acc), do: collect_direct(node, acc)

  defp collect_pipe_node(left, right, meta, acc) do
    case {split_call(left) || enum_map_call(left), pipe_reader(right)} do
      {{:string_split, subject, "/", _split_meta}, {:last, _reader_meta}} ->
        maybe_evidence(
          acc,
          path_subject?(subject),
          :manual_path_basename,
          "manual path basename extraction; use Path.basename/1",
          "Path.basename/1",
          meta,
          :high
        )

      {{:string_split, subject, ".", _split_meta}, {:last, _reader_meta}} ->
        maybe_evidence(
          acc,
          path_subject?(subject),
          :manual_path_extension,
          "manual path extension extraction; use Path.extname/1",
          "Path.extname/1",
          meta,
          :high
        )

      {{:string_split, subject, "?", _split_meta}, {:first, _reader_meta}} ->
        maybe_evidence(
          acc,
          uri_subject?(subject),
          :manual_uri_path_split,
          "manual URL splitting; use URI.parse/1",
          "URI.parse/1",
          meta,
          :medium
        )

      {{:enum_map, _enumerable, _mapper, _map_meta}, {:flatten, _flatten_meta}} ->
        maybe_evidence(
          acc,
          true,
          :manual_flat_map,
          "Enum.map followed by flatten allocates an intermediate nested list; use Enum.flat_map/2",
          "Enum.flat_map/2",
          meta,
          :high
        )

      _ ->
        acc
    end
  end

  defp collect_direct(node, acc) do
    case {split_call(node), map_update_shape(node)} do
      {{:string_split, subject, "&", meta}, _map_update} ->
        maybe_evidence(
          acc,
          uri_subject?(subject),
          :manual_query_parsing,
          "manual query-string splitting; use URI.decode_query/1",
          "URI.decode_query/1",
          meta,
          :medium
        )

      {{:string_split, subject, "://", meta}, _map_update} ->
        maybe_evidence(
          acc,
          uri_subject?(subject),
          :manual_uri_scheme_split,
          "manual URL scheme splitting; use URI.parse/1",
          "URI.parse/1",
          meta,
          :medium
        )

      {_split_call, {:ok, meta}} ->
        maybe_evidence(
          acc,
          true,
          :manual_map_update,
          "Map.get plus paired Map.put branches reimplements Map.update/4",
          "Map.update/4",
          meta,
          :high
        )

      _ ->
        acc
    end
  end

  defp maybe_evidence(acc, false, _kind, _message, _replacement, _meta, _confidence), do: acc

  defp maybe_evidence(acc, true, kind, message, replacement, meta, confidence) do
    [evidence(kind, message, replacement, meta, confidence) | acc]
  end

  defp split_call(
         {:|>, _pipe_meta,
          [
            subject,
            {{:., meta, [{:__aliases__, _, [:String]}, :split]}, _call_meta, [delimiter | _]}
          ]}
       )
       when is_binary(delimiter),
       do: {:string_split, subject, delimiter, meta}

  defp split_call(
         {{:., meta, [{:__aliases__, _, [:String]}, :split]}, _call_meta,
          [subject, delimiter | _]}
       )
       when is_binary(delimiter),
       do: {:string_split, subject, delimiter, meta}

  defp split_call({:split, meta, [subject, delimiter | _]}) when is_binary(delimiter),
    do: {:string_split, subject, delimiter, meta}

  defp split_call(_), do: nil

  defp enum_map_call(
         {{:., meta, [{:__aliases__, _, [:Enum]}, :map]}, _call_meta, [enumerable, mapper]}
       ),
       do: {:enum_map, enumerable, mapper, meta}

  defp enum_map_call(
         {:|>, _pipe_meta,
          [enumerable, {{:., meta, [{:__aliases__, _, [:Enum]}, :map]}, _call_meta, [mapper]}]}
       ),
       do: {:enum_map, enumerable, mapper, meta}

  defp enum_map_call(_node), do: nil

  defp pipe_reader({{:., meta, [{:__aliases__, _, [:List]}, fun]}, _call_meta, []})
       when fun in [:last, :first],
       do: {fun, meta}

  defp pipe_reader({{:., meta, [{:__aliases__, _, [:Enum]}, :at]}, _call_meta, [index]})
       when index in [-1, 0],
       do: {if(index == -1, do: :last, else: :first), meta}

  defp pipe_reader({{:., meta, [{:__aliases__, _, [:List]}, :flatten]}, _call_meta, []}),
    do: {:flatten, meta}

  defp pipe_reader({{:., meta, [{:__aliases__, _, [:Enum]}, :concat]}, _call_meta, []}),
    do: {:flatten, meta}

  defp pipe_reader({fun, meta, []}) when fun in [:hd], do: {:first, meta}
  defp pipe_reader(_), do: nil

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

  defp paired_map_put_branches?(clauses, map, key) when length(clauses) == 2 do
    Enum.all?(clauses, fn
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

  defp same_ast?(left, right), do: Macro.to_string(left) == Macro.to_string(right)

  defp path_subject?(subject), do: subject_name(subject) in @path_names
  defp uri_subject?(subject), do: subject_name(subject) in @uri_names

  defp subject_name({name, _meta, context}) when is_atom(name) and is_atom(context), do: name
  defp subject_name(_), do: nil

  defp evidence(kind, message, replacement, meta, confidence) do
    %Evidence{
      kind: kind,
      message: message,
      replacement: replacement,
      meta: meta,
      confidence: confidence
    }
  end
end
