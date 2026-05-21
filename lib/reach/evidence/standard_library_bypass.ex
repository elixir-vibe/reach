defmodule Reach.Evidence.StandardLibraryBypass do
  @moduledoc "Collects evidence of ad-hoc code that bypasses standard library helpers."

  defmodule Evidence do
    @moduledoc false
    defstruct [:kind, :message, :replacement, :meta, :confidence]
  end

  @path_names ~w(path filepath file_path filename file dir directory source dest destination)a
  @uri_names ~w(url uri href endpoint query query_string qs)a

  def family, do: :stdlib

  def kinds do
    [
      :manual_path_basename,
      :manual_path_extension,
      :manual_query_parsing,
      :manual_uri_path_split,
      :manual_uri_scheme_split,
      :manual_flat_map,
      :manual_map_update,
      :manual_frequencies,
      :manual_frequencies_by,
      :manual_flat_map_reduce,
      :manual_flat_map_prepend_reverse,
      :manual_map_update_bang
    ]
  end

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
    case {split_call(left) || enum_map_call(left) || flat_map_prepend_reverse_call(left),
          pipe_reader(right)} do
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

      {{:flat_map_prepend_reverse, _reduce_meta}, {:reverse, _reverse_meta}} ->
        maybe_evidence(
          acc,
          true,
          :manual_flat_map_prepend_reverse,
          "Enum.reduce with Enum.reverse(chunk, acc) followed by reverse reimplements Enum.flat_map/2",
          "Enum.flat_map/2",
          meta,
          :high
        )

      _ ->
        acc
    end
  end

  defp collect_direct(node, acc) do
    case {split_call(node), map_update_shape(node), frequencies_shape(node),
          flat_map_reduce_shape(node), map_update_bang_shape(node)} do
      {{:string_split, subject, "&", meta}, _map_update, _frequencies, _flat_map_reduce,
       _map_update_bang} ->
        maybe_evidence(
          acc,
          uri_subject?(subject),
          :manual_query_parsing,
          "manual query-string splitting; use URI.decode_query/1",
          "URI.decode_query/1",
          meta,
          :medium
        )

      {{:string_split, subject, "://", meta}, _map_update, _frequencies, _flat_map_reduce,
       _map_update_bang} ->
        maybe_evidence(
          acc,
          uri_subject?(subject),
          :manual_uri_scheme_split,
          "manual URL scheme splitting; use URI.parse/1",
          "URI.parse/1",
          meta,
          :medium
        )

      {_split_call, {:ok, meta}, _frequencies, _flat_map_reduce, _map_update_bang} ->
        maybe_evidence(
          acc,
          true,
          :manual_map_update,
          "Map.get plus paired Map.put branches reimplements Map.update/4",
          "Map.update/4",
          meta,
          :high
        )

      {_split_call, _map_update, {:ok, kind, replacement, meta}, _flat_map_reduce,
       _map_update_bang} ->
        maybe_evidence(
          acc,
          true,
          kind,
          "Enum.reduce builds a count map; use #{replacement}",
          replacement,
          meta,
          :high
        )

      {_split_call, _map_update, _frequencies, {:ok, meta}, _map_update_bang} ->
        maybe_evidence(
          acc,
          true,
          :manual_flat_map_reduce,
          "Enum.reduce appends mapped lists into an accumulator; use Enum.flat_map/2",
          "Enum.flat_map/2",
          meta,
          :high
        )

      {_split_call, _map_update, _frequencies, _flat_map_reduce, {:ok, meta}} ->
        maybe_evidence(
          acc,
          true,
          :manual_map_update_bang,
          "Map.fetch! followed by Map.put on the same key reimplements Map.update!/3",
          "Map.update!/3",
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

  defp flat_map_prepend_reverse_call(node) do
    with {:ok, meta, item, acc, body} <- reduce_empty_list_callback(node),
         true <- reverse_chunk_into_acc?(body, item, acc) do
      {:flat_map_prepend_reverse, meta}
    else
      _other -> nil
    end
  end

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

  defp pipe_reader({{:., meta, [{:__aliases__, _, [:Enum]}, :reverse]}, _call_meta, []}),
    do: {:reverse, meta}

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

  defp same_ast?(left, right), do: Macro.to_string(left) == Macro.to_string(right)

  defp frequencies_shape(node) do
    with {:ok, meta, item, acc, body} <- reduce_empty_map_callback(node),
         {:ok, key} <- count_map_body(body, acc) do
      replacement =
        if same_ast?(key, item), do: "Enum.frequencies/1", else: "Enum.frequencies_by/2"

      kind =
        if replacement == "Enum.frequencies/1",
          do: :manual_frequencies,
          else: :manual_frequencies_by

      {:ok, kind, replacement, meta}
    else
      _other -> :error
    end
  end

  defp reduce_empty_map_callback(
         {{:., meta, [{:__aliases__, _, [:Enum]}, :reduce]}, _call_meta,
          [_enumerable, {:%{}, _, []}, {:fn, _, [{:->, _, [[item, acc], body]}]}]}
       ),
       do: {:ok, meta, item, acc, body}

  defp reduce_empty_map_callback(
         {:|>, _pipe_meta,
          [
            _enumerable,
            {{:., meta, [{:__aliases__, _, [:Enum]}, :reduce]}, _call_meta,
             [{:%{}, _, []}, {:fn, _, [{:->, _, [[item, acc], body]}]}]}
          ]}
       ),
       do: {:ok, meta, item, acc, body}

  defp reduce_empty_map_callback(_node), do: :error

  defp count_map_body(
         {{:., _, [{:__aliases__, _, [:Map]}, :update]}, _, [acc, key, 1, increment_fun]},
         expected_acc
       ) do
    if same_ast?(acc, expected_acc) and increment_by_one_fun?(increment_fun),
      do: {:ok, key},
      else: :error
  end

  defp count_map_body({:__block__, _, [assignment, put_call]}, expected_acc) do
    with {:ok, count_var, key} <- count_assignment(assignment, expected_acc),
         true <- count_put_call?(put_call, expected_acc, key, count_var) do
      {:ok, key}
    else
      _other -> :error
    end
  end

  defp count_map_body(_body, _expected_acc), do: :error

  defp count_assignment(
         {:=, _, [count_var, {{:., _, [{:__aliases__, _, [:Map]}, :get]}, _, [acc, key, 0]}]},
         expected_acc
       ) do
    if same_ast?(acc, expected_acc), do: {:ok, count_var, key}, else: :error
  end

  defp count_assignment(_node, _expected_acc), do: :error

  defp count_put_call?(
         {{:., _, [{:__aliases__, _, [:Map]}, :put]}, _, [acc, key, increment]},
         expected_acc,
         expected_key,
         count_var
       ) do
    same_ast?(acc, expected_acc) and same_ast?(key, expected_key) and
      increment_by_one?(increment, count_var)
  end

  defp count_put_call?(_node, _expected_acc, _expected_key, _count_var), do: false

  defp increment_by_one_fun?({:&, _, [{:+, _, [{:&, _, [1]}, 1]}]}), do: true
  defp increment_by_one_fun?({:&, _, [{:+, _, [1, {:&, _, [1]}]}]}), do: true
  defp increment_by_one_fun?(_node), do: false

  defp increment_by_one?({:+, _, [var, 1]}, expected_var), do: same_ast?(var, expected_var)
  defp increment_by_one?({:+, _, [1, var]}, expected_var), do: same_ast?(var, expected_var)
  defp increment_by_one?(_node, _expected_var), do: false

  defp flat_map_reduce_shape(node) do
    with {:ok, meta, item, acc, body} <- reduce_empty_list_callback(node),
         true <- append_mapped_list?(body, item, acc) do
      {:ok, meta}
    else
      _other -> :error
    end
  end

  defp reduce_empty_list_callback(
         {{:., meta, [{:__aliases__, _, [:Enum]}, :reduce]}, _call_meta,
          [_enumerable, [], {:fn, _, [{:->, _, [[item, acc], body]}]}]}
       ),
       do: {:ok, meta, item, acc, body}

  defp reduce_empty_list_callback(
         {:|>, _pipe_meta,
          [
            _enumerable,
            {{:., meta, [{:__aliases__, _, [:Enum]}, :reduce]}, _call_meta,
             [[], {:fn, _, [{:->, _, [[item, acc], body]}]}]}
          ]}
       ),
       do: {:ok, meta, item, acc, body}

  defp reduce_empty_list_callback(_node), do: :error

  defp append_mapped_list?({:++, _, [left, right]}, item, acc) do
    same_ast?(left, acc) and references_ast?(right, item) and not references_ast?(right, acc)
  end

  defp append_mapped_list?(_body, _item, _acc), do: false

  defp reverse_chunk_into_acc?(
         {{:., _, [{:__aliases__, _, [:Enum]}, :reverse]}, _, [chunk, acc]},
         item,
         expected_acc
       ) do
    same_ast?(acc, expected_acc) and references_ast?(chunk, item) and
      not references_ast?(chunk, acc)
  end

  defp reverse_chunk_into_acc?(_body, _item, _acc), do: false

  defp references_ast?(node, expected) do
    {_node, found?} =
      Macro.prewalk(node, false, fn child, found? ->
        {child, found? or same_ast?(child, expected)}
      end)

    found?
  end

  defp map_update_bang_shape({:__block__, meta, [assignment, put_call]}) do
    with {:ok, value_var, map, key, assignment_meta} <- fetch_bang_assignment(assignment),
         true <- update_bang_put_call?(put_call, map, key, value_var) do
      {:ok, line_meta(assignment_meta, meta)}
    else
      _other -> :error
    end
  end

  defp map_update_bang_shape(put_call) do
    case put_call do
      {{:., meta, [{:__aliases__, _, [:Map]}, :put]}, _, [map, key, value]} ->
        if fetch_bang_value_for?(value, map, key), do: {:ok, meta}, else: :error

      _node ->
        :error
    end
  end

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

  defp line_meta(preferred, fallback) do
    if Keyword.get(preferred, :line), do: preferred, else: fallback
  end

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
