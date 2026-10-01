defmodule Reach.Smell.Checks.RedundantComputation do
  @moduledoc "Detects duplicate pure calls within the same function."

  use Reach.Smell.Check

  alias Reach.Effects
  alias Reach.Smell.ExecutionContext
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

  def run(project) do
    modules = for {_id, node} <- project.nodes, node.type == :module_def, do: node
    contracts = ExecutionContext.function_contracts(modules)

    project
    |> Helpers.function_defs()
    |> Enum.flat_map(&findings(&1, contracts))
  end

  defp findings(func, contracts) do
    func
    |> ExecutionContext.annotate(contracts)
    |> IR.all_nodes()
    |> Enum.filter(&redundancy_candidate?/1)
    |> Enum.group_by(fn node ->
      {node.meta[:smell_execution], node.meta[:module], node.meta[:function], node.meta[:arity],
       Enum.map(node.children, &argument_identity/1)}
    end)
    |> Enum.flat_map(fn {_key, calls} -> find_same_arg_calls(calls) end)
  end

  defp formatting_call?(%{meta: %{function: :to_string, module: Kernel}}), do: true
  defp formatting_call?(%{meta: %{function: :to_string, kind: :local}}), do: true
  defp formatting_call?(%{meta: %{function: :inspect, kind: :local}}), do: true
  defp formatting_call?(%{meta: %{function: :inspect, module: Kernel}}), do: true
  defp formatting_call?(_node), do: false

  @excluded_fns MapSet.new(
                  @type_check_fns ++
                    @compiler_directives ++
                    @pattern_operators ++
                    [:__aliases__, :get]
                )

  @excluded_kinds MapSet.new([:attribute, :field_access, :binary_size])

  defp redundancy_candidate?(node) do
    node.type == :call and node.source_span != nil and node.children != [] and
      not excluded_call?(node) and Effects.pure?(node)
  end

  defp excluded_call?(node) do
    node.meta[:function] == nil or node.meta[:smell_quoted] or
      node.meta[:smell_reachable] == false or node.meta[:function] in @excluded_fns or
      node.meta[:kind] in @excluded_kinds or node.meta[:module] == Access or
      formatting_call?(node)
  end

  defp find_same_arg_calls(calls) do
    {findings, _} =
      Enum.reduce(calls, {[], []}, fn right, {findings, previous} ->
        left =
          Enum.find(previous, fn left ->
            ExecutionContext.compatible?(left, right) and same_args?(left, right) and
              left.source_span[:start_line] != right.source_span[:start_line]
          end)

        additions = if left, do: maybe_redundant_call(left, right), else: []
        {additions ++ findings, [right | previous]}
      end)

    Enum.reverse(findings)
  end

  defp maybe_redundant_call(left, right) do
    if same_args?(left, right) and left.source_span[:start_line] != right.source_span[:start_line] do
      [
        Finding.new(
          kind: :redundant_computation,
          message:
            "#{Helpers.call_name(left)} called twice with same args (line #{left.source_span[:start_line]} and #{right.source_span[:start_line]})",
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

  defp argument_identity(%{type: :var, meta: meta}), do: {:var, meta[:smell_binding]}
  defp argument_identity(%{type: :literal, meta: meta}), do: {:literal, meta[:value]}
  defp argument_identity(node), do: {:expression, node.id}

  defp same_node?(%{type: :var, meta: left}, %{type: :var, meta: right}),
    do: left[:smell_binding] == right[:smell_binding]

  defp same_node?(%{type: :literal, meta: left}, %{type: :literal, meta: right}),
    do: left[:value] == right[:value]

  defp same_node?(_left, _right), do: false
end
