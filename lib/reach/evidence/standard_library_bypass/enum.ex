defmodule Reach.Evidence.StandardLibraryBypass.Enum do
  @moduledoc "Collects Enum standard-library bypass evidence."

  import ExAST.Sigil

  alias Reach.Evidence.AST
  alias Reach.Evidence.PatternRunner
  alias Reach.Evidence.StandardLibraryBypass

  @manual_flat_map_concat_message "Enum.map followed by concat allocates an intermediate nested list; use Enum.flat_map/2"
  @manual_flat_map_flatten_message "Enum.map followed by List.flatten/1 may be Enum.flat_map/2 when the mapper returns a flat list; preserve List.flatten/1 if recursive flattening is required"

  def collect_ast(ast) do
    pattern_evidence(ast) ++ callback_evidence(ast)
  end

  def kinds do
    [
      :manual_flat_map,
      :manual_frequencies,
      :manual_frequencies_by,
      :manual_flat_map_reduce,
      :manual_flat_map_prepend_reverse
    ]
  end

  defp pattern_evidence(ast) do
    PatternRunner.run(ast, pattern_specs(), family: :stdlib)
  end

  defp pattern_specs do
    [
      manual_flat_map_list: {~p[Enum.map(_, _) |> List.flatten()], &manual_flatten_evidence/1},
      manual_flat_map_concat: {~p[Enum.map(_, _) |> Enum.concat()], &manual_concat_evidence/1}
    ]
  end

  defp manual_flatten_evidence(_match) do
    %{
      kind: :manual_flat_map,
      message: @manual_flat_map_flatten_message,
      replacement: "Enum.flat_map/2",
      confidence: :medium
    }
  end

  defp manual_concat_evidence(_match) do
    %{
      kind: :manual_flat_map,
      message: @manual_flat_map_concat_message,
      replacement: "Enum.flat_map/2",
      confidence: :high
    }
  end

  defp callback_evidence(ast) do
    AST.collect(ast, &collect_callback_node/2)
  end

  defp collect_callback_node({:|>, meta, [left, right]} = node, acc) do
    acc = collect_pipe_node(left, right, meta, acc)
    collect_direct(node, acc)
  end

  defp collect_callback_node(node, acc), do: collect_direct(node, acc)

  defp collect_pipe_node(left, right, meta, acc) do
    case {enum_map_call(left) || flat_map_prepend_reverse_call(left), pipe_reader(right)} do
      {{:enum_map, _enumerable, _mapper, _map_meta}, {:flatten, _flatten_meta}} ->
        acc

      {{:flat_map_prepend_reverse, _reduce_meta}, {:reverse, _reverse_meta}} ->
        evidence(
          acc,
          :manual_flat_map_prepend_reverse,
          "Enum.reduce with Enum.reverse(chunk, acc) followed by reverse reimplements Enum.flat_map/2",
          "Enum.flat_map/2",
          meta
        )

      _ ->
        acc
    end
  end

  defp collect_direct(node, acc) do
    case {frequencies_shape(node), flat_map_reduce_shape(node)} do
      {{:ok, kind, replacement, meta}, _flat_map_reduce} ->
        evidence(
          acc,
          kind,
          "Enum.reduce builds a count map; use #{replacement}",
          replacement,
          meta
        )

      {_frequencies, {:ok, meta}} ->
        evidence(
          acc,
          :manual_flat_map_reduce,
          "Enum.reduce appends mapped lists into an accumulator; use Enum.flat_map/2",
          "Enum.flat_map/2",
          meta
        )

      _ ->
        acc
    end
  end

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

  defp pipe_reader({{:., meta, [{:__aliases__, _, [:List]}, :flatten]}, _call_meta, []}),
    do: {:flatten, meta}

  defp pipe_reader({{:., meta, [{:__aliases__, _, [:Enum]}, :concat]}, _call_meta, []}),
    do: {:flatten, meta}

  defp pipe_reader({{:., meta, [{:__aliases__, _, [:Enum]}, :reverse]}, _call_meta, []}),
    do: {:reverse, meta}

  defp pipe_reader(_), do: nil

  defp frequencies_shape(node) do
    with {:ok, meta, item, acc, body} <- reduce_empty_map_callback(node),
         {:ok, key} <- count_map_body(body, acc) do
      replacement =
        if AST.same_ast?(key, item), do: "Enum.frequencies/1", else: "Enum.frequencies_by/2"

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
    if AST.same_ast?(acc, expected_acc) and increment_by_one_fun?(increment_fun),
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
    if AST.same_ast?(acc, expected_acc), do: {:ok, count_var, key}, else: :error
  end

  defp count_assignment(_node, _expected_acc), do: :error

  defp count_put_call?(
         {{:., _, [{:__aliases__, _, [:Map]}, :put]}, _, [acc, key, increment]},
         expected_acc,
         expected_key,
         count_var
       ) do
    AST.same_ast?(acc, expected_acc) and AST.same_ast?(key, expected_key) and
      increment_by_one?(increment, count_var)
  end

  defp count_put_call?(_node, _expected_acc, _expected_key, _count_var), do: false

  defp increment_by_one_fun?({:&, _, [{:+, _, [{:&, _, [1]}, 1]}]}), do: true
  defp increment_by_one_fun?({:&, _, [{:+, _, [1, {:&, _, [1]}]}]}), do: true
  defp increment_by_one_fun?(_node), do: false

  defp increment_by_one?({:+, _, [var, 1]}, expected_var), do: AST.same_ast?(var, expected_var)
  defp increment_by_one?({:+, _, [1, var]}, expected_var), do: AST.same_ast?(var, expected_var)
  defp increment_by_one?(_node, _expected_var), do: false

  defp flat_map_reduce_shape(node) do
    with {:ok, meta, item, acc, body} <- reduce_empty_list_callback(node),
         true <- append_mapped_list?(body, item, acc) do
      {:ok, meta}
    else
      _other -> :error
    end
  end

  defp flat_map_prepend_reverse_call(node) do
    with {:ok, meta, item, acc, body} <- reduce_empty_list_callback(node),
         true <- reverse_chunk_into_acc?(body, item, acc) do
      {:flat_map_prepend_reverse, meta}
    else
      _other -> nil
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
    AST.same_ast?(left, acc) and AST.references?(right, item) and not AST.references?(right, acc) and
      not single_element_literal_list?(right)
  end

  defp append_mapped_list?(_body, _item, _acc), do: false

  defp single_element_literal_list?([_item]), do: true
  defp single_element_literal_list?(_node), do: false

  defp reverse_chunk_into_acc?(
         {{:., _, [{:__aliases__, _, [:Enum]}, :reverse]}, _, [chunk, acc]},
         item,
         expected_acc
       ) do
    AST.same_ast?(acc, expected_acc) and AST.references?(chunk, item) and
      not AST.references?(chunk, acc)
  end

  defp reverse_chunk_into_acc?(_body, _item, _acc), do: false

  defp evidence(acc, kind, message, replacement, meta) do
    [StandardLibraryBypass.fact(kind, message, replacement, meta) | acc]
  end
end
