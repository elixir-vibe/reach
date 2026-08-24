defmodule Reach.Smell.Checks.RedundantComputation do
  @moduledoc "Detects duplicate pure calls within the same function."

  use Reach.Smell.Check

  alias Reach.Effects
  alias Reach.IR.Helpers, as: IRHelpers
  alias Reach.Smell.Finding

  @type_check_fns [
    :is_atom,
    :is_binary,
    :is_bitstring,
    :is_boolean,
    :is_exception,
    :is_float,
    :is_function,
    :is_integer,
    :is_list,
    :is_map,
    :is_map_key,
    :is_nil,
    :is_number,
    :is_pid,
    :is_port,
    :is_reference,
    :is_struct,
    :is_tuple,
    :byte_size,
    :bit_size,
    :tuple_size,
    :map_size
  ]

  @compiler_directives [
    :import,
    :alias,
    :require,
    :use,
    :doc,
    :moduledoc,
    :typedoc,
    :spec,
    :callback,
    :macrocallback,
    :impl,
    :type,
    :typep,
    :opaque,
    :behaviour,
    :defstruct,
    :defdelegate,
    :defmacro,
    :defmacrop,
    :defguard,
    :defguardp,
    :unquote,
    :quote
  ]

  @pattern_operators [:|, :{}, :@, :"::", :<<>>, :size]

  defp findings(func) do
    func
    |> collect_sequential_blocks()
    |> Enum.flat_map(&find_redundant_in_block/1)
  end

  defp find_redundant_in_block(block_calls) do
    block_calls
    |> Enum.group_by(fn node -> {node.meta[:module], node.meta[:function], node.meta[:arity]} end)
    |> Enum.flat_map(fn {_key, group} ->
      if length(group) > 1, do: find_same_arg_calls(group), else: []
    end)
  end

  defp collect_sequential_blocks(node) do
    calls = collect_block_calls(node, []) |> Enum.reverse()

    nested =
      (node.children || [])
      |> Enum.flat_map(fn child ->
        case child.type do
          type when type in [:case, :fn] ->
            child.children
            |> Enum.filter(&(&1.type == :clause))
            |> Enum.flat_map(&collect_sequential_blocks/1)

          :clause ->
            collect_sequential_blocks(child)

          _ ->
            []
        end
      end)

    if calls != [], do: [calls | nested], else: nested
  end

  defp formatting_call?(%{meta: %{function: :to_string, module: Kernel}}), do: true
  defp formatting_call?(%{meta: %{function: :to_string, kind: :local}}), do: true
  defp formatting_call?(%{meta: %{function: :inspect, kind: :local}}), do: true
  defp formatting_call?(%{meta: %{function: :inspect, module: Kernel}}), do: true
  defp formatting_call?(_node), do: false

  defp stateful_helper?(%{meta: %{module: Reach.IR.Counter, function: :next}}), do: true
  defp stateful_helper?(_node), do: false

  @excluded_fns MapSet.new(
                  @type_check_fns ++
                    @compiler_directives ++
                    @pattern_operators ++
                    [:__aliases__, :get]
                )

  @excluded_kinds MapSet.new([:attribute, :field_access, :binary_size])

  defp redundancy_candidate?(node) do
    eligible_call?(node) and pure_source_call?(node)
  end

  defp eligible_call?(node) do
    node.type == :call and node.meta[:function] != nil and node.source_span != nil and
      node.meta[:function] not in @excluded_fns and
      node.meta[:kind] not in @excluded_kinds and node.meta[:module] != Access
  end

  defp pure_source_call?(node) do
    not generated_source_call?(node) and Effects.pure?(node) and not formatting_call?(node) and
      not stateful_helper?(node)
  end

  defp generated_source_call?(%{meta: %{origin: %{generated?: true}}}), do: true
  defp generated_source_call?(_node), do: false

  defp collect_block_calls(node, acc) do
    acc = if redundancy_candidate?(node), do: [node | acc], else: acc

    node.children
    |> Enum.reject(&(&1.type in [:case, :fn, :clause]))
    |> Enum.reduce(acc, &collect_block_calls/2)
  end

  defp find_same_arg_calls(calls) do
    calls
    |> Enum.chunk_every(2, 1, [])
    |> Enum.flat_map(fn
      [left, right] -> maybe_redundant_call(left, right)
      _ -> []
    end)
  end

  defp maybe_redundant_call(left, right) do
    if same_args?(left, right) and left.source_span[:start_line] != right.source_span[:start_line] do
      [
        Finding.new(
          kind: :redundant_computation,
          message:
            "#{IRHelpers.call_name(left)} called twice with same args (line #{left.source_span[:start_line]} and #{right.source_span[:start_line]})",
          location: Helpers.location(right)
        )
      ]
    else
      []
    end
  end

  defp same_args?(left, right) do
    length(left.children) == length(right.children) and left.children != [] and
      Enum.zip(left.children, right.children)
      |> Enum.all?(fn {left_child, right_child} -> same_node?(left_child, right_child) end)
  end

  defp same_node?(%{type: :var, meta: left}, %{type: :var, meta: right}),
    do: left[:name] == right[:name]

  defp same_node?(%{type: :literal, meta: left}, %{type: :literal, meta: right}),
    do: left[:value] == right[:value]

  defp same_node?(_left, _right), do: false
end
