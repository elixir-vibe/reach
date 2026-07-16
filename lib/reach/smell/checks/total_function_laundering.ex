defmodule Reach.Smell.Checks.TotalFunctionLaundering do
  @moduledoc "Detects private domain parsers that silently coerce invalid input to a valid value."

  use Reach.Smell.Check.AST

  alias Reach.Smell.Finding

  @impl true
  def kinds, do: [:total_function_laundering]

  defp scan_ast(ast, file) do
    ast
    |> module_nodes()
    |> Enum.flat_map(&module_findings(&1, file))
  end

  defp module_nodes({:__block__, _meta, statements}) when is_list(statements) do
    Enum.flat_map(statements, &module_nodes/1)
  end

  defp module_nodes({:defmodule, _meta, [_name, body]} = module) do
    [module | nested_modules(keyword_value(body, :do))]
  end

  defp module_nodes(_ast), do: []

  defp nested_modules(body) do
    body
    |> block_statements()
    |> Enum.flat_map(&module_nodes/1)
  end

  defp module_findings({:defmodule, _meta, [_name, body]}, file) do
    statements = block_statements(keyword_value(body, :do))
    type_domains = type_domains(statements)

    statements
    |> Enum.flat_map(&private_clause/1)
    |> Enum.group_by(&{&1.name, &1.arity})
    |> Enum.flat_map(&function_finding(&1, type_domains, file))
  end

  defp private_clause({:defp, meta, [head, body]}) do
    with {call, guards} <- split_guards(head),
         {name, _call_meta, [parameter]} when is_atom(name) <- call,
         {:ok, expression} <- keyword_fetch(body, :do) do
      [
        %{
          name: name,
          arity: 1,
          parameter: parameter,
          guards: guards,
          body: expression,
          meta: meta
        }
      ]
    else
      _unsupported -> []
    end
  end

  defp private_clause(_definition), do: []

  defp function_finding({_signature, clauses}, type_domains, file) do
    clauses = Enum.sort_by(clauses, &(&1.meta[:line] || 0))

    with [catch_all] <- Enum.filter(clauses, &catch_all?/1),
         true <- List.last(clauses) == catch_all,
         {:ok, fallback} <- literal(catch_all.body),
         normal <- Enum.map(List.delete(clauses, catch_all), &normal_clause/1),
         true <- enough_domain_clauses?(normal),
         true <- Enum.all?(normal, &match?({:ok, _inputs, _outputs, true}, &1)),
         inputs <- domain_values(normal, 1),
         outputs <- domain_values(normal, 2),
         declared <- Map.get(type_domains, catch_all.name, MapSet.new()),
         true <- MapSet.member?(MapSet.union(outputs, declared), fallback) do
      [finding(file, catch_all, inputs, fallback, clauses)]
    else
      _not_laundering -> []
    end
  end

  defp enough_domain_clauses?([_first, _second | _rest]), do: true

  defp enough_domain_clauses?(_clauses), do: false

  defp catch_all?(%{guards: [], parameter: parameter}) do
    variable?(parameter)
  end

  defp catch_all?(_clause), do: false

  defp normal_clause(%{guards: [], parameter: parameter, body: body}) do
    with {:ok, input} <- literal(parameter),
         {:ok, output} <- literal(body) do
      {:ok, [input], [output], logical_literal_equal?(input, output)}
    else
      _unsupported -> :error
    end
  end

  defp normal_clause(%{parameter: parameter, guards: guards, body: body}) do
    with {:ok, variable} <- variable_name(parameter),
         {:ok, inputs} <- membership_domain(guards, variable),
         {:ok, outputs, preserving?} <- clause_outputs(body, variable, inputs) do
      {:ok, inputs, outputs, preserving?}
    else
      _unsupported -> :error
    end
  end

  defp clause_outputs(body, variable, inputs) do
    case variable_name(body) do
      {:ok, ^variable} -> {:ok, inputs, true}
      _other -> body |> literal() |> then(&map_literal_result(&1, inputs))
    end
  end

  defp map_literal_result({:ok, value}, inputs) do
    {:ok, [value], Enum.all?(inputs, &logical_literal_equal?(&1, value))}
  end

  defp map_literal_result(:error, _inputs), do: :error

  defp logical_literal_equal?(left, right) when left == right, do: true

  defp logical_literal_equal?(left, right) when is_binary(left) and is_atom(right),
    do: left == Atom.to_string(right)

  defp logical_literal_equal?(left, right) when is_atom(left) and is_binary(right),
    do: Atom.to_string(left) == right

  defp logical_literal_equal?(_left, _right), do: false

  defp membership_domain(guards, variable) do
    guards
    |> Enum.flat_map(&membership_expressions/1)
    |> Enum.find_value(:error, fn
      {:in, _meta, [left, values]} ->
        with {:ok, ^variable} <- variable_name(left),
             values when is_list(values) <- unwrap_block(values),
             parsed when parsed != :error <- literal_list(values) do
          {:ok, parsed}
        else
          _unsupported -> false
        end

      _expression ->
        false
    end)
  end

  defp membership_expressions(expression), do: collect_membership_expressions(expression, [])

  defp collect_membership_expressions({operator, _meta, [left, right]}, expressions)
       when operator in [:and, :andalso] do
    collect_membership_expressions(left, collect_membership_expressions(right, expressions))
  end

  defp collect_membership_expressions(expression, expressions), do: [expression | expressions]

  defp literal_list(values) do
    Enum.reduce_while(values, [], fn value, parsed ->
      case literal(value) do
        {:ok, literal} -> {:cont, [literal | parsed]}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      :error -> :error
      parsed -> Enum.reverse(parsed)
    end
  end

  defp domain_values(clauses, tuple_index) do
    clauses
    |> Enum.flat_map(&elem(&1, tuple_index))
    |> MapSet.new()
  end

  defp type_domains(statements) do
    statements
    |> Enum.flat_map(&type_domain/1)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {name, values} -> {name, values |> List.flatten() |> MapSet.new()} end)
  end

  defp type_domain({:@, _meta, [{kind, _attribute_meta, [{:"::", _type_meta, [head, body]}]}]})
       when kind in [:type, :typep] do
    case type_name(head) do
      nil -> []
      name -> [{name, union_literals(body)}]
    end
  end

  defp type_domain(_statement), do: []

  defp type_name({name, _meta, arguments}) when is_atom(name) and arguments in [nil, []], do: name
  defp type_name(_head), do: nil

  defp union_literals(value), do: collect_union_literals(value, [])

  defp collect_union_literals({:|, _meta, [left, right]}, literals) do
    collect_union_literals(left, collect_union_literals(right, literals))
  end

  defp collect_union_literals(value, literals) do
    case literal(value) do
      {:ok, literal} -> [literal | literals]
      :error -> literals
    end
  end

  defp split_guards({:when, _meta, [head | guards]}), do: {head, guards}
  defp split_guards(head), do: {head, []}

  defp variable?({name, _meta, context}) when is_atom(name) and is_atom(context), do: true
  defp variable?(_value), do: false

  defp variable_name({name, _meta, context}) when is_atom(name) and is_atom(context),
    do: {:ok, name}

  defp variable_name(_value), do: :error

  defp literal(value) do
    case unwrap_block(value) do
      atom when is_atom(atom) and atom not in [nil, true, false] -> {:ok, atom}
      binary when is_binary(binary) -> {:ok, binary}
      number when is_number(number) -> {:ok, number}
      _dynamic -> :error
    end
  end

  defp unwrap_block({:__block__, _meta, [value]}), do: unwrap_block(value)
  defp unwrap_block(value), do: value

  defp block_statements({:__block__, _meta, statements}) when is_list(statements), do: statements
  defp block_statements(nil), do: []
  defp block_statements(statement), do: [statement]

  defp keyword_value(entries, key) when is_list(entries) do
    case keyword_fetch(entries, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp keyword_value(_entries, _key), do: nil

  defp keyword_fetch(entries, key) when is_list(entries) do
    Enum.find_value(entries, :error, fn
      {{:__block__, _meta, [^key]}, value} -> {:ok, value}
      {^key, value} -> {:ok, value}
      _entry -> false
    end)
  end

  defp keyword_fetch(_entries, _key), do: :error

  defp finding(file, catch_all, inputs, fallback, clauses) do
    name = catch_all.name
    line = catch_all.meta[:line] || 0

    Finding.new(
      kind: :total_function_laundering,
      message:
        "private #{name}/1 catch-all silently coerces values outside #{inspect(Enum.sort(inputs))} to #{inspect(fallback)}; define accepted values in one module attribute, guard valid input, and raise or return an error for unsupported input",
      location: %{file: file, line: line, column: catch_all.meta[:column]},
      evidence:
        Enum.map(clauses, fn clause ->
          %{file: file, line: clause.meta[:line] || 0, column: clause.meta[:column]}
        end),
      occurrences: length(clauses),
      confidence: :high,
      source_range: %{
        file: file,
        start_line: line,
        start_col: catch_all.meta[:column],
        end_line: line,
        end_col: catch_all.meta[:column]
      }
    )
  end
end
