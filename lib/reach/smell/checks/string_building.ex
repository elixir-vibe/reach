defmodule Reach.Smell.Checks.StringBuilding do
  @moduledoc "Detects string concatenation where iolists are more efficient."

  use Reach.Smell.Check

  defp findings(func) do
    all_nodes = IR.all_nodes(func)
    calls = Enum.filter(all_nodes, &(&1.type == :call and &1.source_span != nil))

    detect_map_join_interpolation(calls) ++
      detect_map_join_concat(calls) ++
      detect_concat_around_join(all_nodes) ++
      detect_reduce_string_concat(calls, func)
  end

  defp detect_map_join_interpolation(calls) do
    calls
    |> Enum.filter(&enum_call?(&1, :join))
    |> Enum.flat_map(fn join ->
      with %{meta: %{function: :map, module: Enum}} = map_call <- find_piped_producer(join, calls),
           true <- callback_builds_strings?(map_call) do
        [
          finding(
            :string_building,
            "Enum.map with interpolation piped to Enum.join: return iolists instead",
            join
          )
        ]
      else
        _ -> []
      end
    end)
  end

  defp detect_map_join_concat(calls) do
    calls
    |> Enum.filter(&(enum_call?(&1, :map_join) and callback_builds_strings?(&1)))
    |> Enum.map(
      &finding(
        :string_building,
        "Enum.map_join with string interpolation: use Enum.map/2 returning iolists",
        &1
      )
    )
  end

  defp detect_concat_around_join(all_nodes) do
    concats =
      Enum.filter(all_nodes, fn node ->
        node.type == :binary_op and node.meta[:operator] == :<> and node.source_span != nil and
          Enum.any?(IR.all_nodes(node), &enum_call?(&1, :join))
      end)

    nested_ids =
      concats |> Enum.flat_map(&Enum.map(&1.children, fn c -> c.id end)) |> MapSet.new()

    concats
    |> Enum.reject(&(&1.id in nested_ids))
    |> Enum.map(
      &finding(
        :string_building,
        "String concatenation around Enum.join: wrap in a list instead",
        &1
      )
    )
  end

  defp detect_reduce_string_concat(calls, function) do
    calls
    |> Enum.filter(&(enum_call?(&1, :reduce) and callback_grows_string?(&1, function)))
    |> Enum.map(
      &finding(
        :string_building,
        "Enum.reduce building string with <>: O(n²) copying; use iolists or Enum.map_join",
        &1
      )
    )
  end

  defp enum_call?(%{type: :call, meta: %{module: Enum, function: f}}, target), do: f == target
  defp enum_call?(_node, _target), do: false

  defp find_piped_producer(consumer, calls) do
    Enum.find(calls, &(&1.id in Enum.map(consumer.children, fn c -> c.id end)))
  end

  defp callback_builds_strings?(call) do
    call.children
    |> Enum.filter(&(&1.type == :fn))
    |> Enum.any?(fn fn_node ->
      subtree = IR.all_nodes(fn_node)
      has_interpolation?(subtree) or has_concat?(subtree)
    end)
  end

  defp has_interpolation?(nodes),
    do:
      Enum.any?(
        nodes,
        &(&1.type == :call and &1.meta[:function] == :<<>> and &1.meta[:kind] == :local)
      )

  defp has_concat?(nodes),
    do: Enum.any?(nodes, &(&1.type == :binary_op and &1.meta[:operator] == :<>))

  defp callback_grows_string?(call, function) do
    call
    |> IR.all_nodes()
    |> Enum.any?(fn node ->
      ((node.type == :binary_op and node.meta[:operator] == :<>) or
         (node.type == :call and node.meta[:function] == :<<>>)) and
        Helpers.growing_accumulator_concat?(node, function)
    end)
  end
end
