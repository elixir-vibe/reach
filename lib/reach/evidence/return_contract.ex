defmodule Reach.Evidence.ReturnContract do
  @moduledoc "Collects terminal return-shape evidence across clauses and branches."

  alias Reach.Source

  defmodule Outcome do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct [:class, :shape, :label, :line, :column, :nested_same_tag]
  end

  defmodule Fact do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct [
      :module,
      :function,
      :arity,
      :visibility,
      :file,
      :line,
      :impl,
      outcomes: []
    ]
  end

  @spec collect_project(Reach.Project.t()) :: [Fact.t()]
  def collect_project(project) do
    project
    |> Source.project_files()
    |> Enum.flat_map(&collect_file/1)
    |> Enum.sort_by(&{&1.file, &1.line || 0, &1.module, &1.function, &1.arity})
  end

  @doc false
  @spec collect_ast(Macro.t(), Path.t()) :: [Fact.t()]
  def collect_ast(ast, file) do
    ast
    |> Reach.AST.modules_in_file()
    |> Enum.flat_map(&module_facts(&1, file))
  end

  defp collect_file(file) do
    with {:ok, source} <- File.read(file),
         {:ok, ast} <- Code.string_to_quoted(source, columns: true, emit_warnings: false) do
      collect_ast(ast, file)
    else
      _error -> []
    end
  end

  defp module_facts({:defmodule, _meta, [module_ast, body]}, file) do
    with {:ok, module} <- Reach.AST.module_name(module_ast),
         {:ok, module_body} <- Reach.AST.keyword_fetch(body, :do) do
      module_body
      |> statements()
      |> clauses()
      |> Enum.group_by(&{&1.function, &1.arity})
      |> Enum.map(fn {{function, arity}, clauses} ->
        outcomes = Enum.flat_map(clauses, &terminal_outcomes(&1.body, &1.meta))

        %Fact{
          module: module,
          function: function,
          arity: arity,
          visibility: clauses |> List.first() |> Map.fetch!(:visibility),
          file: file,
          line: clauses |> Enum.map(& &1.meta[:line]) |> Enum.reject(&is_nil/1) |> Enum.min(),
          impl: Enum.any?(clauses, & &1.impl),
          outcomes: outcomes
        }
      end)
    else
      _unsupported -> []
    end
  end

  defp module_facts(_module, _file), do: []

  defp clauses(statements) do
    {clauses, _impl} = Enum.reduce(statements, {[], false}, &collect_clause/2)
    Enum.reverse(clauses)
  end

  defp collect_clause({:@, _meta, [{:impl, _, [value]}]}, {clauses, _impl}) do
    {clauses, value != false}
  end

  defp collect_clause(
         {visibility, meta, [head, body]},
         {clauses, impl}
       )
       when visibility in [:def, :defp] do
    case function_clause(head, body, visibility, meta, impl) do
      nil -> {clauses, false}
      clause -> {[clause | clauses], false}
    end
  end

  defp collect_clause(_other, state), do: state

  defp function_clause(head, body, visibility, meta, impl) do
    with {:ok, function, arity} <- Reach.AST.function_identity(head),
         {:ok, expression} <- function_expression(body, meta) do
      %{
        function: function,
        arity: arity,
        visibility: visibility,
        body: expression,
        meta: meta,
        impl: impl
      }
    else
      _unsupported -> nil
    end
  end

  defp function_expression(body, meta) do
    with {:ok, expression} <- Reach.AST.keyword_fetch(body, :do) do
      if Enum.any?([:rescue, :catch, :else], &Reach.AST.keyword?(body, &1)) do
        {:ok, {:try, meta, [body]}}
      else
        {:ok, expression}
      end
    end
  end

  defp terminal_outcomes({:__block__, _meta, []}, fallback),
    do: [outcome(nil, fallback)]

  defp terminal_outcomes({:__block__, _meta, statements}, fallback) when is_list(statements) do
    statements |> List.last() |> terminal_outcomes(fallback)
  end

  defp terminal_outcomes({:case, meta, [_subject, options]}, _fallback) do
    options |> keyword_value(:do, []) |> clause_outcomes(meta)
  end

  defp terminal_outcomes({:cond, meta, [options]}, _fallback) do
    options |> keyword_value(:do, []) |> clause_outcomes(meta)
  end

  defp terminal_outcomes({kind, meta, [_condition, options]}, _fallback)
       when kind in [:if, :unless] and is_list(options) do
    do_outcomes = terminal_outcomes(Keyword.get(options, :do), meta)

    case Keyword.fetch(options, :else) do
      {:ok, else_expression} ->
        Enum.concat(do_outcomes, terminal_outcomes(else_expression, meta))

      :error ->
        Enum.concat(do_outcomes, [outcome(nil, meta)])
    end
  end

  defp terminal_outcomes({:with, meta, arguments}, _fallback) when is_list(arguments) do
    options = List.last(arguments)
    do_outcomes = terminal_outcomes(keyword_value(options, :do), meta)
    else_clauses = keyword_value(options, :else)

    if is_list(else_clauses) do
      Enum.concat(do_outcomes, clause_outcomes(else_clauses, meta))
    else
      Enum.concat(do_outcomes, [dynamic_outcome(meta)])
    end
  end

  defp terminal_outcomes({:receive, meta, [options]}, _fallback) do
    receive_outcomes = options |> keyword_value(:do, []) |> clause_outcomes(meta)

    after_outcomes =
      case keyword_value(options, :after) do
        clauses when is_list(clauses) -> clause_outcomes(clauses, meta)
        _none -> []
      end

    Enum.concat(receive_outcomes, after_outcomes)
  end

  defp terminal_outcomes({:try, meta, [options]}, _fallback) do
    successful =
      case keyword_value(options, :else) do
        nil -> try_outcomes(keyword_value(options, :do), meta)
        else_clauses -> try_outcomes(else_clauses, meta)
      end

    exceptional =
      [:rescue, :catch]
      |> Enum.flat_map(fn key -> try_outcomes(keyword_value(options, key), meta) end)

    Enum.concat(successful, exceptional)
  end

  defp terminal_outcomes(expression, fallback), do: [outcome(expression, fallback)]

  defp try_outcomes(nil, _fallback), do: []

  defp try_outcomes(clauses, fallback) when is_list(clauses),
    do: clause_outcomes(clauses, fallback)

  defp try_outcomes(expression, fallback), do: terminal_outcomes(expression, fallback)

  defp clause_outcomes(clauses, fallback) when is_list(clauses) do
    Enum.flat_map(clauses, fn
      {:->, meta, [_patterns, body]} -> terminal_outcomes(body, meta)
      _dynamic_clause -> [dynamic_outcome(fallback)]
    end)
  end

  defp clause_outcomes(_dynamic, fallback), do: [dynamic_outcome(fallback)]

  defp outcome(expression, fallback) do
    {class, shape, label, nested_same_tag} = classify(expression)
    meta = expression_meta(expression) || fallback || []

    %Outcome{
      class: class,
      shape: shape,
      label: label,
      line: meta[:line],
      column: meta[:column],
      nested_same_tag: nested_same_tag
    }
  end

  defp dynamic_outcome(meta), do: outcome({:__reach_dynamic_return__, meta || [], []}, meta)

  defp classify(expression) do
    case tuple_shape(expression) do
      {:ok, tag, arity, elements} ->
        nested = nested_same_tag?(tag, Enum.at(elements, 1))
        {:tagged, {:tagged, tag, arity}, tagged_label(tag, arity), nested}

      {:tuple, arity} ->
        {:tuple, {:tuple, arity}, "#{arity}-tuple", nil}

      :error ->
        classify_non_tuple(expression)
    end
  end

  defp classify_non_tuple(value) when is_boolean(value),
    do: {:boolean, :boolean, inspect(value), nil}

  defp classify_non_tuple(nil), do: {nil, nil, "nil", nil}

  defp classify_non_tuple(value) when is_atom(value),
    do: {:bare_atom, {:bare_atom, value}, inspect(value), nil}

  defp classify_non_tuple(value) when is_binary(value), do: {:scalar, :binary, "binary", nil}
  defp classify_non_tuple(value) when is_integer(value), do: {:scalar, :integer, "integer", nil}
  defp classify_non_tuple(value) when is_float(value), do: {:scalar, :float, "float", nil}
  defp classify_non_tuple(value) when is_list(value), do: {:list, :list, "list", nil}

  defp classify_non_tuple({:%{}, _meta, _fields}), do: {:map, :map, "map", nil}

  defp classify_non_tuple({:%, _meta, [module_ast, _map]}) do
    module = module_label(module_ast)
    {:struct, {:struct, module}, "%#{module}{}", nil}
  end

  defp classify_non_tuple({:<<>>, _meta, _parts}), do: {:scalar, :binary, "binary", nil}

  defp classify_non_tuple(expression) do
    if no_return_call?(expression) do
      {:no_return, :no_return, "no return", nil}
    else
      {:dynamic, :dynamic, "dynamic value", nil}
    end
  end

  defp tuple_shape({:{}, _meta, elements}) when is_list(elements),
    do: tuple_elements_shape(elements)

  defp tuple_shape(tuple) when is_tuple(tuple) and tuple_size(tuple) == 2,
    do: tuple |> Tuple.to_list() |> tuple_elements_shape()

  defp tuple_shape(_expression), do: :error

  defp tuple_elements_shape([tag | _rest] = elements) when is_atom(tag),
    do: {:ok, tag, length(elements), elements}

  defp tuple_elements_shape(elements), do: {:tuple, length(elements)}

  defp nested_same_tag?(tag, expression) do
    case tuple_shape(expression) do
      {:ok, ^tag, _arity, _elements} -> tag
      _other -> nil
    end
  end

  defp tagged_label(tag, arity) do
    values = [inspect(tag) | List.duplicate("_", max(arity - 1, 0))]
    ["{", Enum.intersperse(values, ", "), "}"] |> IO.iodata_to_binary()
  end

  defp no_return_call?(expression) do
    case Reach.AST.call(expression) do
      {_module, function, _args} -> function in [:raise, :throw, :exit]
      nil -> false
    end
  end

  defp expression_meta({_form, meta, _args}) when is_list(meta), do: meta
  defp expression_meta(_expression), do: nil

  defp module_label({:__aliases__, _meta, _parts} = alias_ast) do
    case Reach.AST.module_name(alias_ast) do
      {:ok, module} -> inspect(module)
      :error -> Macro.to_string(alias_ast)
    end
  end

  defp module_label(module) when is_atom(module), do: inspect(module)
  defp module_label(_dynamic), do: "struct"

  defp statements({:__block__, _meta, statements}) when is_list(statements), do: statements
  defp statements(statement), do: [statement]

  defp keyword_value(keyword, key, default \\ nil)

  defp keyword_value(keyword, key, default) when is_list(keyword),
    do: Keyword.get(keyword, key, default)

  defp keyword_value(_dynamic, _key, default), do: default
end
