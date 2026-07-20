defmodule Reach.Evidence.TotalFunctionLaundering do
  @moduledoc "Collects private domain parsers whose catch-all returns an accepted domain value."

  @behaviour Reach.Evidence.Provider

  alias Reach.Evidence.AST
  alias Reach.Source

  defmodule Fact do
    @moduledoc "Evidence about a closed-domain parser with an accepted-value fallback."

    @type t :: %__MODULE__{
            name: atom(),
            arity: 1,
            file: Path.t() | nil,
            inputs: MapSet.t(),
            outputs: MapSet.t(),
            declared_domain: MapSet.t(),
            fallback: term(),
            fallback_explicit?: boolean(),
            catch_all: map(),
            clauses: [map()]
          }

    defstruct [
      :name,
      :arity,
      :file,
      :inputs,
      :outputs,
      :declared_domain,
      :fallback,
      :catch_all,
      clauses: [],
      fallback_explicit?: false
    ]
  end

  @impl true
  def family, do: :domain_fallback

  @impl true
  def kinds, do: [:accepted_domain_fallback]

  @impl true
  def collect_ast(ast), do: collect_ast(ast, nil)

  @doc false
  @spec collect_ast(Macro.t(), Path.t() | nil) :: [Fact.t()]
  def collect_ast(ast, file) do
    ast
    |> module_nodes()
    |> Enum.flat_map(&module_facts(&1, file))
  end

  @spec collect_project(Reach.Project.t()) :: [Fact.t()]
  def collect_project(project) do
    project
    |> Source.project_files()
    |> Enum.flat_map(&collect_file/1)
    |> Enum.sort_by(&{&1.file, &1.catch_all.meta[:line] || 0, &1.name})
  end

  defp collect_file(file) do
    case AST.parse_file(file) do
      {:ok, ast} -> collect_ast(ast, file)
      {:error, _reason} -> []
    end
  end

  defp module_nodes({:__block__, _meta, statements}) when is_list(statements) do
    Enum.flat_map(statements, &module_nodes/1)
  end

  defp module_nodes({:defmodule, _meta, [_name, body]} = module) do
    [module | nested_modules(Reach.AST.keyword_value(body, :do))]
  end

  defp module_nodes(_ast), do: []

  defp nested_modules(body) do
    body
    |> block_statements()
    |> Enum.flat_map(&module_nodes/1)
  end

  defp module_facts({:defmodule, _meta, [_name, body]}, file) do
    statements = block_statements(Reach.AST.keyword_value(body, :do))
    type_domains = type_domains(statements)

    statements
    |> Enum.flat_map(&private_clause/1)
    |> Enum.group_by(&{&1.name, &1.arity})
    |> Enum.flat_map(&function_fact(&1, type_domains, file))
  end

  defp private_clause({:defp, meta, [head, body]}) do
    with {call, guards} <- split_guards(head),
         {name, _call_meta, [parameter]} when is_atom(name) <- call,
         {:ok, expression} <- Reach.AST.keyword_fetch(body, :do) do
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

  defp function_fact({_signature, clauses}, type_domains, file) do
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
      [
        %Fact{
          name: catch_all.name,
          arity: 1,
          file: file,
          inputs: inputs,
          outputs: outputs,
          declared_domain: declared,
          fallback: fallback,
          fallback_explicit?: Enum.any?(inputs, &logical_literal_equal?(&1, fallback)),
          catch_all: catch_all,
          clauses: clauses
        }
      ]
    else
      _not_laundering -> []
    end
  end

  defp enough_domain_clauses?([_first, _second | _rest]), do: true
  defp enough_domain_clauses?(_clauses), do: false

  defp catch_all?(%{guards: [], parameter: parameter}), do: variable?(parameter)
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
end
