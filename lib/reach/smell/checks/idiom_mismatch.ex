defmodule Reach.Smell.Checks.IdiomMismatch do
  @moduledoc "Detects non-idiomatic patterns such as guard equality and update-then-fetch."

  use Reach.Smell.Check

  defp findings(function) do
    guard_equality_findings(function) ++
      map_update_then_fetch(function) ++
      redundant_negated_guard(function) ++
      destructure_reconstruct(function) ++
      length_in_guard(function)
  end

  defp guard_equality_findings(function) do
    function.children
    |> Enum.filter(&(&1.type == :clause and &1.meta[:kind] == :function_clause))
    |> Enum.flat_map(&guard_equalities(&1, function))
  end

  defp guard_equalities(clause, function) do
    parameters =
      clause.children
      |> Enum.take(function.meta[:arity])
      |> Enum.filter(&(&1.type == :var))
      |> Enum.map(& &1.meta[:name])

    clause.children
    |> Enum.filter(&(&1.type == :guard))
    |> Enum.flat_map(fn guard ->
      conjuncts = Enum.flat_map(guard.children, &guard_conjuncts/1)

      for equality <- conjuncts,
          equality.type == :binary_op,
          equality.meta[:operator] in [:==, :===],
          equality.source_span,
          head_match_equivalent?(equality, parameters, conjuncts) do
        finding(
          :suboptimal,
          "guard compares parameter to literal; use pattern matching in the function head",
          equality
        )
      end
    end)
  end

  defp guard_conjuncts(%{type: :binary_op, meta: %{operator: :and}, children: children}),
    do: Enum.flat_map(children, &guard_conjuncts/1)

  defp guard_conjuncts(node), do: [node]

  defp head_match_equivalent?(%{children: [left, right]} = equality, parameters, conjuncts) do
    literal_parameter?(left, right, equality, parameters, conjuncts) or
      literal_parameter?(right, left, equality, parameters, conjuncts)
  end

  defp head_match_equivalent?(_, _, _), do: false

  defp literal_parameter?(
         %{type: :literal, meta: %{value: value}},
         %{type: :var, meta: %{name: name}},
         equality,
         parameters,
         conjuncts
       )
       when is_atom(value) or is_binary(value) or is_integer(value) or is_float(value) do
    name in parameters and
      (equality.meta[:operator] == :=== or not is_number(value) or
         integer_parameter?(name, value, conjuncts))
  end

  defp literal_parameter?(_, _, _, _, _), do: false

  # == accepts 0.0 as well as 0; a literal head does not. An integer type
  # constraint in the same conjunction is required before suggesting that rewrite.
  defp integer_parameter?(name, value, conjuncts) do
    is_integer(value) and
      Enum.any?(conjuncts, fn
        %{
          type: :call,
          meta: %{function: :is_integer, module: module},
          children: [%{type: :var, meta: %{name: parameter}}]
        } ->
          module in [nil, Kernel] and parameter == name

        _ ->
          false
      end)
  end

  defp map_update_then_fetch(function) do
    Helpers.statement_pairs(function)
    |> Enum.flat_map(fn {first, second} ->
      update_var = map_update_binding(first)
      fetch_var = map_fetch_on(second)

      if update_var && fetch_var && update_var == fetch_var do
        [
          finding(
            :suboptimal,
            "Map.update then Map.get/fetch on same variable traverses twice; compute value first with Map.get, then Map.put",
            second
          )
        ]
      else
        []
      end
    end)
  end

  defp map_update_binding(%{type: :match, children: [%{type: :var, meta: %{name: var}}, call]}) do
    if call.type == :call and call.meta[:module] == Map and
         call.meta[:function] in [:update, :update!] do
      var
    end
  end

  defp map_update_binding(_), do: nil

  defp map_fetch_on(node) do
    node
    |> IR.all_nodes()
    |> Enum.find_value(&map_fetch_var/1)
  end

  defp map_fetch_var(%{
         type: :call,
         meta: %{module: Map, function: f},
         children: [%{type: :var, meta: %{name: var}} | _]
       })
       when f in [:get, :fetch, :fetch!],
       do: var

  defp map_fetch_var(_), do: nil

  # --- Redundant negated guard ---

  defp redundant_negated_guard(function) do
    clauses =
      function.children
      |> Enum.filter(&(&1.type == :clause and &1.meta[:kind] == :function_clause))

    clauses
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [prev, curr] -> check_guard_pair(prev, curr, function) end)
  end

  defp check_guard_pair(prev_clause, curr_clause, function) do
    with {:ok, :==, prev_left, prev_right} <- extract_guard_comparison(prev_clause),
         {:ok, :!=, curr_left, curr_right} <- extract_guard_comparison(curr_clause),
         true <- same_var_name?(prev_left, curr_left) and same_var_name?(prev_right, curr_right) do
      [
        finding(
          :suboptimal,
          "redundant negated guard; the preceding clause already handles the complementary case",
          (curr_clause.source_span && curr_clause) || function
        )
      ]
    else
      _ -> []
    end
  end

  defp extract_guard_comparison(clause) do
    clause.children
    |> Enum.find(&(&1.type == :guard))
    |> guard_to_comparison()
  end

  defp guard_to_comparison(nil), do: :error

  defp guard_to_comparison(guard) do
    guard
    |> IR.all_nodes()
    |> Enum.find(&(&1.type == :binary_op and &1.meta[:operator] in [:==, :!=, :===, :!==]))
    |> case do
      %{meta: %{operator: op}, children: [left, right]} ->
        normalized_op = if op in [:==, :===], do: :==, else: :!=
        {:ok, normalized_op, left, right}

      _ ->
        :error
    end
  end

  defp same_var_name?(%{type: :var, meta: %{name: a}}, %{type: :var, meta: %{name: b}}),
    do: a == b

  defp same_var_name?(_, _), do: false

  # --- Destructure then reconstruct ---

  defp destructure_reconstruct(function) do
    all_nodes = IR.all_nodes(function)

    all_nodes
    |> Enum.filter(&(&1.type == :clause and &1.meta[:kind] in [:case_clause, :function_clause]))
    |> Enum.flat_map(&check_clause_destructure/1)
  end

  defp check_clause_destructure(clause) do
    patterns = Enum.filter(clause.children, &(&1.type == :list))

    body =
      Enum.reject(
        clause.children,
        &(&1.type == :list or &1.type == :guard or &1.meta[:binding_role] == :definition)
      )

    Enum.flat_map(patterns, fn pattern ->
      var_names = extract_list_var_names(pattern)

      if length(var_names) >= 3 and body_rebuilds_list?(body, var_names) do
        [
          finding(
            :suboptimal,
            "list destructured into [#{Enum.join(var_names, ", ")}] then reassembled; bind as a whole with `= name`",
            (pattern.source_span && pattern) || clause
          )
        ]
      else
        []
      end
    end)
  end

  defp extract_list_var_names(%{type: :list, children: children}) do
    names =
      Enum.map(children, fn
        %{type: :var, meta: %{name: name}} ->
          str = Atom.to_string(name)
          if String.starts_with?(str, "_"), do: nil, else: name

        _ ->
          nil
      end)

    if Enum.any?(names, &is_nil/1), do: [], else: names
  end

  defp body_rebuilds_list?(body, target_names) do
    body
    |> Enum.flat_map(&IR.all_nodes/1)
    |> Enum.any?(fn
      %{type: :list, children: children} ->
        extract_list_var_names(%{type: :list, children: children}) == target_names

      _ ->
        false
    end)
  end

  # --- Length in guard ---

  defp length_in_guard(function) do
    function.children
    |> Enum.filter(&function_clause?/1)
    |> Enum.flat_map(&clause_length_guard_findings(&1, function))
  end

  defp function_clause?(%{type: :clause, meta: %{kind: :function_clause}}), do: true
  defp function_clause?(_), do: false

  defp clause_length_guard_findings(clause, function) do
    clause.children
    |> Enum.filter(&(&1.type == :guard))
    |> Enum.flat_map(&guard_length_findings(&1, function))
  end

  defp guard_length_findings(guard, function) do
    guard
    |> IR.all_nodes()
    |> Enum.filter(&length_comparison?/1)
    |> Enum.map(&length_guard_finding(&1, function))
  end

  defp length_guard_finding(node, function) do
    finding(
      :suboptimal,
      "length/1 in guard is O(n); use list pattern matching instead",
      (node.source_span && node) || function
    )
  end

  defp length_comparison?(%{type: :binary_op, meta: %{operator: op}, children: [left, right]})
       when op in [:==, :>, :>=] do
    length_call?(left) and small_literal?(right)
  end

  defp length_comparison?(%{type: :binary_op, meta: %{operator: op}, children: [left, right]})
       when op in [:==, :<, :<=] do
    small_literal?(left) and length_call?(right)
  end

  defp length_comparison?(_), do: false

  defp length_call?(%{type: :call, meta: %{function: :length, kind: :local}}), do: true
  defp length_call?(_), do: false

  defp small_literal?(%{type: :literal, meta: %{value: n}})
       when is_integer(n) and n >= 0 and n <= 5,
       do: true

  defp small_literal?(_), do: false
end
