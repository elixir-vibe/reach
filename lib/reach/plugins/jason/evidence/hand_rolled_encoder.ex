defmodule Reach.Plugins.Jason.Evidence.HandRolledEncoder do
  @moduledoc "Collects evidence of manual JSON encoding that Jason can own."

  defmodule Evidence do
    @moduledoc false
    defstruct [:kind, :message, :replacement, :meta, :confidence]
  end

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
    {_ast, evidence} =
      Macro.prewalk(ast, [], fn node, acc ->
        {node, collect_node(node, acc)}
      end)

    evidence
    |> Enum.reverse()
    |> Enum.uniq_by(fn evidence ->
      {evidence.kind, evidence.meta[:line], evidence.meta[:column]}
    end)
  end

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

  defp collect_node(
         {:defimpl, meta, [{:__aliases__, _, [:Jason, :Encoder]}, opts, _block]} = node,
         acc
       ) do
    if single_encoder_target?(opts) and delegates_directly_to_to_map?(node) do
      [
        evidence(
          :manual_jason_encoder_map,
          "Jason encoder delegates through a hand-written to_map/1; use @derive Jason.Encoder when the struct projection is direct",
          "@derive Jason.Encoder",
          meta,
          :medium
        )
        | acc
      ]
    else
      acc
    end
  end

  defp collect_node(_node, acc), do: acc

  defp json_boundary_body?(node) do
    count_calls(node, [
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
    contains_call?(node, {:erlang_json, :encode}) or
      contains_call?(node, {String, :duplicate}) or
      contains_call?(node, {String, :replace})
  end

  defp single_encoder_target?(for: {:__aliases__, _, _module_parts}), do: true
  defp single_encoder_target?(_opts), do: false

  defp delegates_directly_to_to_map?(node) do
    {_node, found?} =
      Macro.prewalk(node, false, fn
        {{:., _, [{:__aliases__, _, [:Jason, :Encode]}, :map]}, _, [to_map_call, _opts]} = child,
        _found? ->
          {child, to_map_call?(to_map_call)}

        child, found? ->
          {child, found?}
      end)

    found?
  end

  defp count_calls(node, targets) do
    {_node, count} =
      Macro.prewalk(node, 0, fn child, count ->
        if Enum.any?(targets, &call?(child, &1)), do: {child, count + 1}, else: {child, count}
      end)

    count
  end

  defp contains_call?(node, target) do
    {_node, found?} =
      Macro.prewalk(node, false, fn child, found? ->
        {child, found? or call?(child, target)}
      end)

    found?
  end

  defp to_map_call?({:to_map, _meta, args}) when is_list(args), do: true
  defp to_map_call?({{:., _, [_module, :to_map]}, _, args}) when is_list(args), do: true
  defp to_map_call?(_node), do: false

  defp call?({name, _meta, args}, {:__local__, name}) when is_list(args), do: true

  defp call?({{:., _, [{:__aliases__, _, module_parts}, function]}, _, args}, {module, function})
       when is_list(args),
       do: Module.concat(module_parts) == module

  defp call?({{:., _, [:json, :encode]}, _, args}, {:erlang_json, :encode}) when is_list(args),
    do: true

  defp call?({{:., _, [:json, :encode_value]}, _, args}, {:erlang_json, :encode})
       when is_list(args),
       do: true

  defp call?(_node, _target), do: false

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
