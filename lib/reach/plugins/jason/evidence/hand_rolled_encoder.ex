defmodule Reach.Plugins.Jason.Evidence.HandRolledEncoder do
  @moduledoc "Collects evidence of manual JSON encoding that Jason can own."

  alias Reach.Evidence.AST
  alias Reach.Evidence.Fact

  @json_sanitizer_names [:json_safe, :normalize_json, :json_key, :json_safe_key]
  @json_encoder_names [:encode_json, :do_encode, :encode_scalar, :indent_json, :indent_lines]

  def family, do: :jason

  def kinds do
    [
      :hand_rolled_json_sanitizer,
      :hand_rolled_json_encoder,
      :manual_jason_encoder_map
    ]
  end

  def collect_ast(ast) do
    ast
    |> callback_evidence()
    |> Kernel.++(manual_jason_encoder_evidence(ast))
    |> Enum.uniq_by(fn evidence ->
      {evidence.kind, canonical_line(evidence.meta[:line]), evidence.meta[:column]}
    end)
  end

  defp callback_evidence(ast), do: AST.collect(ast, &collect_node/2)

  defp collect_node({def_kind, _meta, [{name, meta, _args} | _]} = node, acc)
       when def_kind in [:def, :defp] and name in @json_sanitizer_names do
    if json_boundary_body?(node) do
      [
        evidence(
          :hand_rolled_json_sanitizer,
          "hand-rolled JSON sanitizer; prefer Jason.Encoder implementations at the domain boundary",
          "Jason.Encoder",
          meta,
          :high
        )
        | acc
      ]
    else
      acc
    end
  end

  defp collect_node({def_kind, _meta, [{name, meta, _args} | _]} = node, acc)
       when def_kind in [:def, :defp] and name in @json_encoder_names do
    if manual_json_writer_body?(node) do
      [
        evidence(
          :hand_rolled_json_encoder,
          "hand-rolled JSON encoder or pretty-printer; use Jason.encode/2",
          "Jason.encode/2",
          meta,
          :high
        )
        | acc
      ]
    else
      acc
    end
  end

  defp collect_node(_node, acc), do: acc

  defp manual_jason_encoder_evidence(ast) do
    if direct_to_map_projection?(ast),
      do: AST.collect(ast, &collect_manual_jason_encoder_node/2),
      else: []
  end

  defp collect_manual_jason_encoder_node(node, acc) do
    if direct_jason_encoder_map?(node) do
      [
        evidence(
          :manual_jason_encoder_map,
          "Jason encoder delegates through a direct to_map/1 projection; use @derive Jason.Encoder",
          "@derive Jason.Encoder",
          jason_encoder_meta(node),
          :high
        )
        | acc
      ]
    else
      acc
    end
  end

  defp json_boundary_body?(node) do
    AST.count_calls(node, [
      {:__local__, :json_safe},
      {:__local__, :normalize_json},
      {Map, :from_struct},
      {DateTime, :to_iso8601},
      {NaiveDateTime, :to_iso8601},
      {Atom, :to_string},
      {Tuple, :to_list}
    ]) >= 2
  end

  defp manual_json_writer_body?(node) do
    AST.contains_call?(node, {String, :duplicate}) or
      AST.contains_call?(node, {String, :replace})
  end

  defp direct_jason_encoder_map?(
         {{:., _, [{:__aliases__, _, [:Jason, :Encode]}, :map]}, _, [to_map_call, _opts]}
       ) do
    to_map_call?(to_map_call)
  end

  defp direct_jason_encoder_map?(_node), do: false

  defp to_map_call?({:to_map, _meta, args}) when is_list(args), do: true
  defp to_map_call?({{:., _, [_module, :to_map]}, _, args}) when is_list(args), do: true
  defp to_map_call?(_node), do: false

  defp direct_to_map_projection?(ast) do
    AST.contains?(ast, fn
      {def_kind, _meta, [{:to_map, _to_map_meta, [_arg]}, [do: body]]}
      when def_kind in [:def, :defp] ->
        direct_map_from_struct?(body)

      _node ->
        false
    end)
  end

  defp direct_map_from_struct?({{:., _, [{:__aliases__, _, [:Map]}, :from_struct]}, _, [_value]}),
    do: true

  defp direct_map_from_struct?(
         {:|>, _, [_value, {{:., _, [{:__aliases__, _, [:Map]}, :from_struct]}, _, []}]}
       ),
       do: true

  defp direct_map_from_struct?(_body), do: false

  defp jason_encoder_meta({{:., meta, [{:__aliases__, _, [:Jason, :Encode]}, :map]}, _, _args}),
    do: meta

  defp jason_encoder_meta(_node), do: [line: :jason_encoder_map]

  defp canonical_line(line) when is_atom(line), do: line
  defp canonical_line(_line), do: :json_writer

  defp evidence(kind, message, replacement, meta, confidence) do
    %Fact{
      family: :jason,
      kind: kind,
      message: message,
      replacement: replacement,
      meta: meta,
      confidence: confidence
    }
  end
end
