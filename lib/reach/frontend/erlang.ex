defmodule Reach.Frontend.Erlang do
  @moduledoc """
  Translates Erlang abstract forms into Reach IR nodes.

  Parses Erlang source via `:epp.parse_file/2` and translates
  the abstract format into the same IR used by the Elixir frontend.
  """

  alias Reach.IR.{Counter, Node}
  import Reach.IR.Helpers, only: [mark_as_definitions: 1]

  @doc """
  Parses an Erlang source file and returns the IR.
  """
  @spec parse_file(Path.t(), keyword()) :: {:ok, [Node.t()]} | {:error, term()}
  def parse_file(path, opts \\ []) do
    include_dirs = Keyword.get(opts, :includes, [])

    case :epp.parse_file(to_charlist(path), include_dirs) do
      {:ok, forms} ->
        counter = Keyword.get_lazy(opts, :counter, &Counter.new/0)
        module = source_module(forms)

        nodes =
          forms
          |> Enum.reject(fn
            {:eof, _} -> true
            {:attribute, _, :file, _} -> true
            _ -> false
          end)
          |> Enum.map(&translate_form(&1, counter, path))
          |> Enum.map(&put_owner_module(&1, module))

        {:ok, nodes}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Parses an Erlang source string and returns the IR.
  """
  @spec parse_string(String.t(), keyword()) :: {:ok, [Node.t()]} | {:error, term()}
  def parse_string(source, opts \\ []) do
    path = Keyword.get(opts, :file, "nofile.erl")
    tmp_dir = Path.join(System.tmp_dir!(), "reach_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    tmp = Path.join(tmp_dir, "source.erl")

    try do
      File.write!(tmp, source)
      parse_file(tmp, Keyword.put(opts, :file, path))
    after
      File.rm_rf(tmp_dir)
    end
  end

  # --- Translation ---

  defp source_module(forms) do
    Enum.find_value(forms, fn
      {:attribute, _line, :module, module} -> module
      _other -> nil
    end)
  end

  @doc false
  def put_owner_module(%Node{} = node, module) do
    meta =
      case node do
        %{type: :function_def} ->
          Map.put(node.meta, :module, module)

        %{type: :call, meta: %{kind: kind}} when kind in [:local, :fun_ref] ->
          node.meta
          |> Map.put(:owner_module, module)
          |> Map.put_new(:module, module)

        _other ->
          node.meta
      end

    %{node | meta: meta, children: Enum.map(node.children, &put_owner_module(&1, module))}
  end

  # Module attribute
  def translate_form({:attribute, line, name, value}, counter, file) do
    %Node{
      id: Counter.next(counter),
      type: :call,
      meta: %{function: name, kind: :attribute, value: value},
      source_span: erl_span(line, file)
    }
  end

  # Function definition
  def translate_form({:function, line, name, arity, clauses}, counter, file) do
    clause_nodes = Enum.map(clauses, &translate_clause(&1, counter, file))

    %Node{
      id: Counter.next(counter),
      type: :function_def,
      meta: %{name: name, arity: arity, kind: :def},
      children: clause_nodes,
      source_span: erl_span(line, file)
    }
  end

  # Catch-all for other top-level forms
  def translate_form(form, counter, file) do
    translate_expr(form, counter, file)
  end

  # --- Clause translation ---

  defp translate_clause({:clause, line, patterns, guards, body}, counter, file) do
    pattern_nodes =
      Enum.map(patterns, &translate_expr(&1, counter, file)) |> Enum.map(&mark_as_definitions/1)

    guard_nodes = translate_guards(guards, counter, file)

    body_nodes = Enum.map(body, &translate_expr(&1, counter, file))

    body_node =
      case body_nodes do
        [single] -> single
        multiple -> %Node{id: Counter.next(counter), type: :block, children: multiple}
      end

    %Node{
      id: Counter.next(counter),
      type: :clause,
      meta: %{kind: :function_clause},
      children: pattern_nodes ++ guard_nodes ++ [body_node],
      source_span: erl_span(line, file)
    }
  end

  # --- Expression translation ---

  # Integer
  defp translate_expr({:integer, _line, value}, counter, _file) do
    %Node{id: Counter.next(counter), type: :literal, meta: %{value: value}}
  end

  # Float
  defp translate_expr({:float, _line, value}, counter, _file) do
    %Node{id: Counter.next(counter), type: :literal, meta: %{value: value}}
  end

  # Atom
  defp translate_expr({:atom, _line, value}, counter, _file) do
    %Node{id: Counter.next(counter), type: :literal, meta: %{value: value}}
  end

  # String (char list in Erlang)
  defp translate_expr({:string, _line, value}, counter, _file) do
    %Node{id: Counter.next(counter), type: :literal, meta: %{value: to_string(value)}}
  end

  # Character
  defp translate_expr({:char, _line, value}, counter, _file) do
    %Node{id: Counter.next(counter), type: :literal, meta: %{value: value}}
  end

  # Variable
  defp translate_expr({:var, line, name}, counter, file) do
    %Node{
      id: Counter.next(counter),
      type: :var,
      meta: %{name: name, context: nil},
      source_span: erl_span(line, file)
    }
  end

  # Nil (empty list)
  defp translate_expr({nil, _line}, counter, _file) do
    %Node{id: Counter.next(counter), type: :list, children: []}
  end

  # Tuple
  defp translate_expr({:tuple, line, elements}, counter, file) do
    children = Enum.map(elements, &translate_expr(&1, counter, file))

    %Node{
      id: Counter.next(counter),
      type: :tuple,
      children: children,
      source_span: erl_span(line, file)
    }
  end

  # Cons cell
  defp translate_expr({:cons, line, head, tail}, counter, file) do
    head_node = translate_expr(head, counter, file)
    tail_node = translate_expr(tail, counter, file)

    %Node{
      id: Counter.next(counter),
      type: :cons,
      children: [head_node, tail_node],
      source_span: erl_span(line, file)
    }
  end

  # Binary operator
  defp translate_expr({:op, line, op, left, right}, counter, file) do
    left_node = translate_expr(left, counter, file)
    right_node = translate_expr(right, counter, file)

    %Node{
      id: Counter.next(counter),
      type: :binary_op,
      meta: %{operator: op},
      children: [left_node, right_node],
      source_span: erl_span(line, file)
    }
  end

  # Unary operator
  defp translate_expr({:op, line, op, operand}, counter, file) do
    operand_node = translate_expr(operand, counter, file)

    %Node{
      id: Counter.next(counter),
      type: :unary_op,
      meta: %{operator: op},
      children: [operand_node],
      source_span: erl_span(line, file)
    }
  end

  # Match
  defp translate_expr({:match, line, pattern, expr}, counter, file) do
    left = translate_expr(pattern, counter, file) |> mark_as_definitions()
    right = translate_expr(expr, counter, file)

    %Node{
      id: Counter.next(counter),
      type: :match,
      children: [left, right],
      source_span: erl_span(line, file)
    }
  end

  # Local call
  defp translate_expr({:call, line, {:atom, _, name}, args}, counter, file) do
    arg_nodes = Enum.map(args, &translate_expr(&1, counter, file))

    %Node{
      id: Counter.next(counter),
      type: :call,
      meta: %{function: name, arity: length(args), kind: :local},
      children: arg_nodes,
      source_span: erl_span(line, file)
    }
  end

  # Remote call: module:function(args)
  defp translate_expr(
         {:call, line, {:remote, _, {:atom, _, mod}, {:atom, _, fun}}, args},
         counter,
         file
       ) do
    arg_nodes = Enum.map(args, &translate_expr(&1, counter, file))

    %Node{
      id: Counter.next(counter),
      type: :call,
      meta: %{module: mod, function: fun, arity: length(args), kind: :remote},
      children: arg_nodes,
      source_span: erl_span(line, file)
    }
  end

  # Dynamic call
  defp translate_expr({:call, line, fun_expr, args}, counter, file) do
    fun_node = translate_expr(fun_expr, counter, file)
    arg_nodes = Enum.map(args, &translate_expr(&1, counter, file))

    %Node{
      id: Counter.next(counter),
      type: :call,
      meta: %{kind: :dynamic, arity: length(args)},
      children: [fun_node | arg_nodes],
      source_span: erl_span(line, file)
    }
  end

  # Case
  defp translate_expr({:case, line, expr, clauses}, counter, file) do
    expr_node = translate_expr(expr, counter, file)

    clause_nodes =
      clauses
      |> Enum.with_index()
      |> Enum.map(fn {{:clause, cl, pats, guards, body}, index} ->
        translate_case_clause({:clause, cl, pats, guards, body}, index, counter, file)
      end)

    %Node{
      id: Counter.next(counter),
      type: :case,
      children: [expr_node | clause_nodes],
      source_span: erl_span(line, file)
    }
  end

  # If (Erlang if is like cond)
  defp translate_expr({:if, line, clauses}, counter, file) do
    clause_nodes =
      clauses
      |> Enum.with_index()
      |> Enum.map(fn {{:clause, cl, [], guards, body}, index} ->
        translate_case_clause({:clause, cl, [], guards, body}, index, counter, file)
      end)

    %Node{
      id: Counter.next(counter),
      type: :case,
      meta: %{desugared_from: :if},
      children: clause_nodes,
      source_span: erl_span(line, file)
    }
  end

  # Try
  defp translate_expr({:try, line, body, else_clauses, catch_clauses, after_body}, counter, file) do
    body_nodes = Enum.map(body, &translate_expr(&1, counter, file))

    body_node =
      case body_nodes do
        [single] -> single
        multiple -> %Node{id: Counter.next(counter), type: :block, children: multiple}
      end

    catch_nodes =
      Enum.with_index(catch_clauses, fn {:clause, cl, pats, _guards, cbody}, index ->
        pattern_nodes = Enum.map(pats, &translate_expr(&1, counter, file))
        body_ir = Enum.map(cbody, &translate_expr(&1, counter, file))

        body_block =
          case body_ir do
            [s] -> s
            m -> %Node{id: Counter.next(counter), type: :block, children: m}
          end

        %Node{
          id: Counter.next(counter),
          type: :catch_clause,
          meta: %{index: index},
          children: pattern_nodes ++ [body_block],
          source_span: erl_span(cl, file)
        }
      end)

    after_nodes =
      case after_body do
        [] ->
          []

        exprs ->
          after_children = Enum.map(exprs, &translate_expr(&1, counter, file))

          [
            %Node{
              id: Counter.next(counter),
              type: :after,
              children: after_children
            }
          ]
      end

    else_nodes =
      Enum.with_index(else_clauses, fn {:clause, cl, pats, guards, ebody}, index ->
        translate_case_clause({:clause, cl, pats, guards, ebody}, index, counter, file)
      end)

    %Node{
      id: Counter.next(counter),
      type: :try,
      children: [body_node] ++ catch_nodes ++ after_nodes ++ else_nodes,
      source_span: erl_span(line, file)
    }
  end

  # Receive
  defp translate_expr({:receive, line, clauses}, counter, file) do
    clause_nodes = translate_receive_clauses(clauses, counter, file)

    %Node{
      id: Counter.next(counter),
      type: :receive,
      children: clause_nodes,
      source_span: erl_span(line, file)
    }
  end

  # Receive with timeout
  defp translate_expr({:receive, line, clauses, timeout, timeout_body}, counter, file) do
    clause_nodes = translate_receive_clauses(clauses, counter, file)

    timeout_node = translate_expr(timeout, counter, file)
    timeout_body_node = translate_body(timeout_body, counter, file)

    timeout_clause = %Node{
      id: Counter.next(counter),
      type: :clause,
      meta: %{kind: :timeout_clause},
      children: [timeout_node, timeout_body_node]
    }

    %Node{
      id: Counter.next(counter),
      type: :receive,
      children: clause_nodes ++ [timeout_clause],
      source_span: erl_span(line, file)
    }
  end

  # Fun (anonymous function)
  defp translate_expr({:fun, line, {:clauses, clauses}}, counter, file) do
    clause_nodes =
      clauses
      |> Enum.with_index()
      |> Enum.map(fn {{:clause, cl, pats, guards, body}, index} ->
        pats_ir = Enum.map(pats, &translate_expr(&1, counter, file))
        guards_ir = translate_guards(guards, counter, file)
        body_ir = translate_body(body, counter, file)

        %Node{
          id: Counter.next(counter),
          type: :clause,
          meta: %{kind: :fn_clause, index: index},
          children: pats_ir ++ guards_ir ++ [body_ir],
          source_span: erl_span(cl, file)
        }
      end)

    %Node{
      id: Counter.next(counter),
      type: :fn,
      children: clause_nodes,
      source_span: erl_span(line, file)
    }
  end

  # Fun reference: fun Module:Function/Arity
  defp translate_expr(
         {:fun, line, {:function, {:atom, _, mod}, {:atom, _, fun}, {:integer, _, arity}}},
         counter,
         file
       ) do
    translate_expr({:fun, line, {:function, mod, fun, arity}}, counter, file)
  end

  defp translate_expr({:fun, line, {:function, mod, fun, arity}}, counter, file) do
    %Node{
      id: Counter.next(counter),
      type: :call,
      meta: %{module: mod, function: fun, arity: arity, kind: :fun_ref},
      source_span: erl_span(line, file)
    }
  end

  # Fun reference: fun Function/Arity
  defp translate_expr({:fun, line, {:function, fun, arity}}, counter, file) do
    %Node{
      id: Counter.next(counter),
      type: :call,
      meta: %{function: fun, arity: arity, kind: :fun_ref},
      source_span: erl_span(line, file)
    }
  end

  # List comprehension
  defp translate_expr({:lc, line, expr, qualifiers}, counter, file) do
    body_node = translate_expr(expr, counter, file)

    qualifier_nodes =
      Enum.map(qualifiers, fn
        {:generate, gl, pattern, enum} ->
          %Node{
            id: Counter.next(counter),
            type: :generator,
            children: [
              translate_expr(pattern, counter, file),
              translate_expr(enum, counter, file)
            ],
            source_span: erl_span(gl, file)
          }

        filter ->
          %Node{
            id: Counter.next(counter),
            type: :filter,
            children: [translate_expr(filter, counter, file)]
          }
      end)

    %Node{
      id: Counter.next(counter),
      type: :comprehension,
      children: qualifier_nodes ++ [body_node],
      source_span: erl_span(line, file)
    }
  end

  # Map creation
  defp translate_expr({:map, line, pairs}, counter, file) do
    children = Enum.map(pairs, &translate_map_field(&1, counter, file))

    %Node{
      id: Counter.next(counter),
      type: :map,
      children: children,
      source_span: erl_span(line, file)
    }
  end

  # Map update
  defp translate_expr({:map, line, base, pairs}, counter, file) do
    base_node = translate_expr(base, counter, file)
    field_nodes = Enum.map(pairs, &translate_map_field(&1, counter, file))

    %Node{
      id: Counter.next(counter),
      type: :map,
      meta: %{kind: :update},
      children: [base_node | field_nodes],
      source_span: erl_span(line, file)
    }
  end

  # Record (translate as tuple-like)
  defp translate_expr({:record, line, name, fields}, counter, file) do
    field_nodes = Enum.map(fields, &translate_record_field(&1, counter, file))

    %Node{
      id: Counter.next(counter),
      type: :struct,
      meta: %{name: name},
      children: field_nodes,
      source_span: erl_span(line, file)
    }
  end

  # Binary/bitstring
  defp translate_expr({:bin, line, elements}, counter, file) do
    children = Enum.map(elements, &translate_bin_element(&1, counter, file))

    %Node{
      id: Counter.next(counter),
      type: :literal,
      meta: %{kind: :binary},
      children: children,
      source_span: erl_span(line, file)
    }
  end

  # Block (begin...end)
  defp translate_expr({:block, _line, exprs}, counter, file) do
    children = Enum.map(exprs, &translate_expr(&1, counter, file))

    %Node{
      id: Counter.next(counter),
      type: :block,
      children: children
    }
  end

  # Catch-all
  defp translate_expr(_form, counter, _file) do
    %Node{id: Counter.next(counter), type: :literal, meta: %{value: nil, raw: true}}
  end

  # --- Helpers ---

  defp translate_case_clause({:clause, line, pats, guards, body}, index, counter, file) do
    pats_ir =
      Enum.map(pats, &translate_expr(&1, counter, file)) |> Enum.map(&mark_as_definitions/1)

    guards_ir = translate_guards(guards, counter, file)
    body_ir = translate_body(body, counter, file)

    %Node{
      id: Counter.next(counter),
      type: :clause,
      meta: %{kind: :case_clause, index: index},
      children: pats_ir ++ guards_ir ++ [body_ir],
      source_span: erl_span(line, file)
    }
  end

  defp translate_receive_clauses(clauses, counter, file) do
    clauses
    |> Enum.with_index()
    |> Enum.map(fn {{:clause, cl, pats, guards, body}, index} ->
      pats_ir = Enum.map(pats, &translate_expr(&1, counter, file))
      guards_ir = translate_guards(guards, counter, file)
      body_ir = translate_body(body, counter, file)

      %Node{
        id: Counter.next(counter),
        type: :clause,
        meta: %{kind: :receive_clause, index: index},
        children: pats_ir ++ guards_ir ++ [body_ir],
        source_span: erl_span(cl, file)
      }
    end)
  end

  defp translate_guards(guards, counter, file) do
    Enum.map(guards, fn guard_seq ->
      guard_exprs = Enum.map(guard_seq, &translate_expr(&1, counter, file))

      %Node{
        id: Counter.next(counter),
        type: :guard,
        children: guard_exprs
      }
    end)
  end

  defp translate_body(exprs, counter, file) do
    children = Enum.map(exprs, &translate_expr(&1, counter, file))

    case children do
      [single] -> single
      multiple -> %Node{id: Counter.next(counter), type: :block, children: multiple}
    end
  end

  defp translate_map_field({:map_field_assoc, _line, key, val}, counter, file) do
    %Node{
      id: Counter.next(counter),
      type: :map_field,
      children: [translate_expr(key, counter, file), translate_expr(val, counter, file)]
    }
  end

  defp translate_map_field({:map_field_exact, _line, key, val}, counter, file) do
    %Node{
      id: Counter.next(counter),
      type: :map_field,
      meta: %{kind: :exact},
      children: [translate_expr(key, counter, file), translate_expr(val, counter, file)]
    }
  end

  defp translate_record_field({:record_field, _line, {:atom, _, name}, val}, counter, file) do
    %Node{
      id: Counter.next(counter),
      type: :map_field,
      children: [
        %Node{id: Counter.next(counter), type: :literal, meta: %{value: name}},
        translate_expr(val, counter, file)
      ]
    }
  end

  defp translate_record_field(_, counter, _file) do
    %Node{id: Counter.next(counter), type: :literal, meta: %{value: nil, raw: true}}
  end

  defp translate_bin_element({:bin_element, _line, expr, _size, _type}, counter, file) do
    translate_expr(expr, counter, file)
  end

  defp erl_span(anno, file) do
    line = normalize_line(:erl_anno.line(anno))
    col = normalize_col(:erl_anno.column(anno))
    %{file: to_string(file), start_line: line, start_col: col, end_line: nil, end_col: nil}
  end

  defp normalize_line(l) when is_integer(l) and l > 0, do: l
  defp normalize_line(_), do: nil

  defp normalize_col(c) when is_integer(c) and c > 0, do: c
  defp normalize_col(_), do: nil
end
