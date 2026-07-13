defmodule Reach.Smell.Checks.FalseSuccessError do
  @moduledoc "Detects validation/check functions that turn error tuples into success-like values."

  use Reach.Smell.Check.AST

  alias Reach.Smell.Finding

  @suspicious_names ~w(check lint validate verify format compile parse)
  @success_atoms [:ok, :ignore, :ignored, :skip, :skipped]

  @impl true
  def kinds, do: [:false_success_error]

  defp scan_ast(ast, file) do
    {_ast, findings} =
      Macro.prewalk(ast, [], fn
        {kind, _meta, [head, body]} = node, findings when kind in [:def, :defp] ->
          {node, findings ++ findings_for_function(head, body, file)}

        node, findings ->
          {node, findings}
      end)

    findings
  end

  defp findings_for_function(head, body, file) do
    if suspicious_function?(head) do
      body
      |> error_clauses()
      |> Enum.filter(&success_like_error_clause?/1)
      |> Enum.map(fn {:->, meta, _args} -> finding(file, meta) end)
    else
      []
    end
  end

  defp suspicious_function?({:when, _meta, [head | _guards]}), do: suspicious_function?(head)

  defp suspicious_function?({name, _meta, _args}) when is_atom(name) do
    name = Atom.to_string(name)

    not String.starts_with?(name, "maybe_") and
      name
      |> String.split("_")
      |> Enum.any?(&(&1 in @suspicious_names))
  end

  defp suspicious_function?(_head), do: false

  defp error_clauses(ast) do
    {_ast, clauses} =
      Macro.prewalk(ast, [], fn
        {:case, _meta, [subject, clause_block]} = node, clauses ->
          new_clauses =
            if suspicious_result_source?(subject) do
              collect_error_clauses(clause_block)
            else
              []
            end

          {node, new_clauses ++ clauses}

        node, clauses ->
          {node, clauses}
      end)

    Enum.reverse(clauses)
  end

  defp collect_error_clauses(clause_block) do
    clauses = arrow_clauses(clause_block)

    if inverted_success_error?(clauses) do
      []
    else
      Enum.filter(clauses, fn
        {:->, _meta, [[pattern], _body]} -> error_tuple_pattern?(pattern)
        _clause -> false
      end)
    end
  end

  defp arrow_clauses({:__block__, _meta, clauses}) when is_list(clauses), do: clauses

  defp arrow_clauses({key, clauses}) when key in [:do, :else] and is_list(clauses),
    do: arrow_clauses(clauses)

  defp arrow_clauses({{:__block__, _meta, [key]}, clauses})
       when key in [:do, :else] and is_list(clauses),
       do: arrow_clauses(clauses)

  defp arrow_clauses(block) when is_list(block) do
    if Enum.all?(block, &arrow_clause?/1) do
      block
    else
      block
      |> Enum.filter(fn
        {key, _value} -> literal_atom(key) in [:do, :else]
        _entry -> false
      end)
      |> Enum.flat_map(fn {_key, value} -> arrow_clauses(value) end)
    end
  end

  defp arrow_clauses(_block), do: []

  defp arrow_clause?({:->, _meta, _args}), do: true
  defp arrow_clause?(_node), do: false

  defp inverted_success_error?(clauses) do
    Enum.any?(clauses, fn
      {:->, _meta, [[pattern], body]} -> ok_pattern?(pattern) and contains_error_like?(body)
      _clause -> false
    end)
  end

  defp ok_pattern?(pattern),
    do: literal_atom(pattern) == :ok or match?([head | _] when head == :ok, tuple_atoms(pattern))

  defp tuple_atoms(pattern), do: Enum.map(tuple_items(pattern), &literal_atom/1)

  defp suspicious_result_source?(subject) do
    subject
    |> call_parts()
    |> Enum.any?(fn part -> part in @suspicious_names end)
  end

  defp call_parts({{:., _meta, [module, function]}, _call_meta, _args}) when is_atom(function) do
    module_parts(module) ++ split_atom(function)
  end

  defp call_parts({:__block__, _meta, [value]}), do: call_parts(value)
  defp call_parts({function, _meta, _args}) when is_atom(function), do: split_atom(function)
  defp call_parts(_subject), do: []

  defp module_parts({:__aliases__, _meta, parts}), do: Enum.flat_map(parts, &split_atom/1)
  defp module_parts(atom) when is_atom(atom), do: split_atom(atom)
  defp module_parts({:__block__, _meta, [value]}), do: module_parts(value)
  defp module_parts(_module), do: []

  defp split_atom(atom) when is_atom(atom) do
    atom
    |> Atom.to_string()
    |> Macro.underscore()
    |> String.split(~r/[^a-z0-9]+|_/, trim: true)
  end

  defp split_atom(_non_atom), do: []

  defp error_tuple_pattern?(pattern) do
    case tuple_items(pattern) do
      [head | _rest] -> literal_atom(head) == :error
      _other -> false
    end
  end

  defp tuple_items({:{}, _meta, items}) when is_list(items), do: items
  defp tuple_items({:__block__, _meta, [items]}) when is_list(items), do: items
  defp tuple_items({:__block__, _meta, [{left, right}]}), do: [left, right]
  defp tuple_items(_pattern), do: []

  defp success_like_error_clause?({:->, _meta, [_patterns, body]}) do
    success_like?(unwrap_block(body))
  end

  defp success_like?([]), do: true
  defp success_like?({:__block__, _meta, [[]]}), do: true
  defp success_like?({:__block__, _meta, [value]}), do: success_like?(value)
  defp success_like?({:__block__, _meta, []}), do: true
  defp success_like?({atom, _meta, context}) when is_atom(atom) and is_atom(context), do: false
  defp success_like?(atom) when atom in @success_atoms, do: true
  defp success_like?(true), do: true
  defp success_like?(false), do: false
  defp success_like?(_other), do: false

  defp contains_error_like?(value) do
    {_ast, found?} =
      Macro.prewalk(value, error_like?(unwrap_block(value)), fn node, found? ->
        {node, found? or error_like?(unwrap_block(node))}
      end)

    found?
  end

  defp error_like?(value) do
    case tuple_items(value) do
      [head | _rest] -> literal_atom(head) == :error
      _other -> literal_atom(value) == :error
    end
  end

  defp unwrap_block({:__block__, _meta, [value]}), do: value
  defp unwrap_block(value), do: value

  defp literal_atom({:__block__, _meta, [atom]}) when is_atom(atom), do: atom
  defp literal_atom(atom) when is_atom(atom), do: atom
  defp literal_atom(_value), do: nil

  defp finding(file, meta) do
    Finding.new(
      kind: :false_success_error,
      message:
        "error branch in check/validate-style function returns a success-like value; report or propagate the error instead",
      location: %{file: file, line: meta[:line] || 0, column: meta[:column]}
    )
  end
end
