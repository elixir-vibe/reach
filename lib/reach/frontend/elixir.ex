defmodule Reach.Frontend.Elixir do
  @moduledoc """
  Translates Elixir AST into Reach IR nodes.

  Parses Elixir source via `Code.string_to_quoted/2` and normalizes
  the AST into expression-level IR nodes.
  """

  alias Reach.IR.{Counter, Node}
  import Reach.IR.Helpers, only: [mark_as_definitions: 1]

  @doc """
  Parses an Elixir source string and returns the IR.
  """
  @spec parse(String.t(), keyword()) :: {:ok, [Node.t()]} | {:error, term()}
  def parse(source, opts \\ []) do
    file = Keyword.get(opts, :file, "nofile")

    case Code.string_to_quoted(source,
           columns: true,
           token_metadata: true,
           emit_warnings: false,
           file: file
         ) do
      {:ok, ast} ->
        counter = Keyword.get(opts, :counter, Counter.new())
        nodes = translate(ast, counter, file)
        {:ok, List.wrap(nodes)}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Same as `parse/2` but raises on error.
  """
  @spec parse!(String.t(), keyword()) :: [Node.t()]
  def parse!(source, opts \\ []) do
    case parse(source, opts) do
      {:ok, nodes} -> nodes
      {:error, reason} -> raise ArgumentError, "Parse error: #{inspect(reason)}"
    end
  end

  @doc false
  def translate_ast(ast, counter, file) do
    result = translate(ast, counter, file)
    List.wrap(result)
  end

  # --- Translation ---

  # Cons cell: [head | tail]
  defp translate([{:|, meta, [head, tail]}], counter, file) do
    head_node = translate(head, counter, file)
    tail_node = translate(tail, counter, file)

    %Node{
      id: Counter.next(counter),
      type: :cons,
      children: [head_node, tail_node],
      source_span: span_from_meta(meta, file)
    }
  end

  # List literal
  defp translate(list, counter, file) when is_list(list) do
    children = Enum.map(list, &translate(&1, counter, file))

    %Node{
      id: Counter.next(counter),
      type: :list,
      children: children
    }
  end

  # Literals: integers, floats, atoms, strings
  defp translate(literal, counter, _file)
       when is_integer(literal) or is_float(literal) or is_binary(literal) do
    %Node{
      id: Counter.next(counter),
      type: :literal,
      meta: %{value: literal}
    }
  end

  defp translate(literal, counter, _file) when is_atom(literal) do
    %Node{
      id: Counter.next(counter),
      type: :literal,
      meta: %{value: literal}
    }
  end

  # Variable reference
  defp translate({name, meta, context}, counter, file)
       when is_atom(name) and is_atom(context) do
    %Node{
      id: Counter.next(counter),
      type: :var,
      meta: %{name: name, context: context},
      source_span: span_from_meta(meta, file)
    }
  end

  # Block
  defp translate({:__block__, meta, exprs}, counter, file) do
    children = Enum.map(exprs, &translate(&1, counter, file))

    %Node{
      id: Counter.next(counter),
      type: :block,
      children: children,
      source_span: span_from_meta(meta, file)
    }
  end

  # Module definition
  defp translate({:defmodule, meta, [alias_ast, [do: body]]}, counter, file) do
    module = module_name_for_def(alias_ast)

    translate_module_body(module, body, meta, counter, file)
  end

  # Protocol definition: defprotocol Protocol
  defp translate({:defprotocol, meta, [protocol_ast, [do: body]]}, counter, file) do
    protocol = module_name_for_def(protocol_ast)

    translate_module_body(protocol, body, meta, counter, file)
  end

  # Protocol implementation: defimpl Protocol, for: Target
  defp translate({:defimpl, meta, [protocol_ast, opts, [do: body]]}, counter, file)
       when is_list(opts) do
    protocol = module_name(protocol_ast)
    target = Keyword.get(opts, :for)
    module = protocol_impl_module(protocol, target)

    translate_module_body(module, body, meta, counter, file)
  end

  # Function definitions: def, defp
  defp translate({def_kind, meta, [{:when, _, [head | guards]}, [do: body]]}, counter, file)
       when def_kind in [:def, :defp] do
    translate_function_def(def_kind, meta, head, guards, body, counter, file)
  end

  defp translate({def_kind, meta, [head, [do: body]]}, counter, file)
       when def_kind in [:def, :defp] do
    translate_function_def(def_kind, meta, head, [], body, counter, file)
  end

  # Multi-clause function definitions (bare clause, no body block)
  defp translate({def_kind, meta, [head]}, counter, file)
       when def_kind in [:def, :defp] do
    {name, arity} = fun_name_arity(head)

    %Node{
      id: Counter.next(counter),
      type: :function_def,
      meta: %{
        name: name,
        arity: arity,
        kind: def_kind,
        has_body: false,
        module: Process.get(:reach_current_module)
      },
      children: [],
      source_span: span_from_meta(meta, file)
    }
  end

  # Pipe operator — desugar into nested calls
  defp translate({:|>, meta, [left, right]}, counter, file) do
    desugared = desugar_pipe(left, right)
    node = translate(desugared, counter, file)

    %{
      node
      | meta: Map.put(node.meta, :desugared_from, :pipe),
        source_span: span_from_meta(meta, file)
    }
  end

  # if/unless — desugar into case
  defp translate({kind, meta, [condition, branches]}, counter, file)
       when kind in [:if, :unless] and is_list(branches) do
    do_body = Keyword.get(branches, :do, nil)
    else_body = Keyword.get(branches, :else, nil)

    {true_body, false_body} =
      if kind == :if, do: {do_body, else_body}, else: {else_body, do_body}

    condition_node = translate(condition, counter, file)
    true_node = translate_nullable(true_body, counter, file)
    false_node = translate_nullable(false_body, counter, file)

    true_clause = %Node{
      id: Counter.next(counter),
      type: :clause,
      meta: %{kind: :true_branch},
      children: [true_node],
      source_span: first_child_span(true_node)
    }

    false_clause = %Node{
      id: Counter.next(counter),
      type: :clause,
      meta: %{kind: :false_branch},
      children: [false_node],
      source_span: first_child_span(false_node)
    }

    %Node{
      id: Counter.next(counter),
      type: :case,
      meta: %{desugared_from: kind},
      children: [condition_node, true_clause, false_clause],
      source_span: span_from_meta(meta, file)
    }
  end

  # cond — desugar into case
  defp translate({:cond, meta, [[do: clauses]]}, counter, file)
       when is_list(clauses) do
    children =
      Enum.map(clauses, fn {:->, clause_meta, [[condition], body]} ->
        cond_node = translate(condition, counter, file)
        body_node = translate(body, counter, file)

        %Node{
          id: Counter.next(counter),
          type: :clause,
          meta: %{kind: :cond_clause},
          children: [cond_node, body_node],
          source_span: span_from_meta(clause_meta, file)
        }
      end)

    %Node{
      id: Counter.next(counter),
      type: :case,
      meta: %{desugared_from: :cond},
      children: children,
      source_span: span_from_meta(meta, file)
    }
  end

  # case
  defp translate({:case, meta, [expr, [do: clauses]]}, counter, file)
       when is_list(clauses) do
    expr_node = translate(expr, counter, file)

    clause_nodes =
      Enum.with_index(clauses, fn {:->, clause_meta, [patterns, body]}, index ->
        {pattern_nodes, guard_nodes} = extract_patterns_and_guards(patterns, counter, file)
        body_node = translate(body, counter, file)

        %Node{
          id: Counter.next(counter),
          type: :clause,
          meta: %{kind: :case_clause, index: index},
          children: pattern_nodes ++ guard_nodes ++ [body_node],
          source_span: span_from_meta(clause_meta, file)
        }
      end)

    %Node{
      id: Counter.next(counter),
      type: :case,
      children: [expr_node | clause_nodes],
      source_span: span_from_meta(meta, file)
    }
  end

  # with
  defp translate({:with, meta, clauses_and_body}, counter, file) do
    {clauses, opts} = split_with_clauses(clauses_and_body)
    opts = List.flatten(opts)
    do_body = Keyword.get(opts, :do)
    else_clauses = Keyword.get(opts, :else, [])

    clause_nodes =
      Enum.map(clauses, fn
        {:<-, clause_meta, [pattern, expr]} ->
          pattern_node = translate(pattern, counter, file)
          expr_node = translate(expr, counter, file)

          %Node{
            id: Counter.next(counter),
            type: :clause,
            meta: %{kind: :with_clause},
            children: [pattern_node, expr_node],
            source_span: span_from_meta(clause_meta, file)
          }

        {_, bare_meta, _} = bare_expr ->
          %Node{
            id: Counter.next(counter),
            type: :clause,
            meta: %{kind: :with_clause},
            children: [translate(bare_expr, counter, file)],
            source_span: span_from_meta(bare_meta, file)
          }

        other ->
          %Node{
            id: Counter.next(counter),
            type: :clause,
            meta: %{kind: :with_clause},
            children: [translate(other, counter, file)],
            source_span: nil
          }
      end)

    body_node = translate(do_body, counter, file)

    else_nodes =
      if is_list(else_clauses) do
        Enum.with_index(else_clauses, fn {:->, clause_meta, [patterns, body]}, index ->
          {pattern_nodes, guard_nodes} = extract_patterns_and_guards(patterns, counter, file)
          body_ir = translate(body, counter, file)

          %Node{
            id: Counter.next(counter),
            type: :clause,
            meta: %{kind: :else_clause, index: index},
            children: pattern_nodes ++ guard_nodes ++ [body_ir],
            source_span: span_from_meta(clause_meta, file)
          }
        end)
      else
        []
      end

    %Node{
      id: Counter.next(counter),
      type: :case,
      meta: %{desugared_from: :with},
      children: clause_nodes ++ [body_node | else_nodes],
      source_span: span_from_meta(meta, file)
    }
  end

  # try
  defp translate({:try, meta, [[do: body] ++ rest]}, counter, file) do
    body_node = translate(body, counter, file)

    rescue_nodes = translate_handler_clauses(rest[:rescue], :rescue, counter, file)
    catch_nodes = translate_handler_clauses(rest[:catch], :catch_clause, counter, file)

    after_node =
      case rest[:after] do
        nil ->
          []

        after_body ->
          [
            %Node{
              id: Counter.next(counter),
              type: :after,
              children: [translate(after_body, counter, file)]
            }
          ]
      end

    else_nodes = translate_handler_clauses(rest[:else], :clause, counter, file)

    %Node{
      id: Counter.next(counter),
      type: :try,
      children: [body_node] ++ rescue_nodes ++ catch_nodes ++ after_node ++ else_nodes,
      source_span: span_from_meta(meta, file)
    }
  end

  # receive
  defp translate({:receive, meta, [[do: clauses] ++ rest]}, counter, file)
       when is_list(clauses) do
    clause_nodes =
      Enum.with_index(clauses, fn {:->, clause_meta, [patterns, body]}, index ->
        {pattern_nodes, guard_nodes} = extract_patterns_and_guards(patterns, counter, file)
        body_node = translate(body, counter, file)

        %Node{
          id: Counter.next(counter),
          type: :clause,
          meta: %{kind: :receive_clause, index: index},
          children: pattern_nodes ++ guard_nodes ++ [body_node],
          source_span: span_from_meta(clause_meta, file)
        }
      end)

    after_node =
      case rest[:after] do
        nil ->
          []

        [{:->, after_meta, [[timeout], body]}] ->
          timeout_node = translate(timeout, counter, file)
          body_node = translate(body, counter, file)

          [
            %Node{
              id: Counter.next(counter),
              type: :clause,
              meta: %{kind: :timeout_clause},
              children: [timeout_node, body_node],
              source_span: span_from_meta(after_meta, file)
            }
          ]
      end

    %Node{
      id: Counter.next(counter),
      type: :receive,
      children: clause_nodes ++ after_node,
      source_span: span_from_meta(meta, file)
    }
  end

  # Anonymous function
  defp translate({:fn, meta, clauses}, counter, file) do
    clause_nodes =
      Enum.with_index(clauses, fn {:->, clause_meta, [params, body]}, index ->
        {pattern_nodes, guard_nodes} = extract_patterns_and_guards(params, counter, file)
        body_node = translate(body, counter, file)

        %Node{
          id: Counter.next(counter),
          type: :clause,
          meta: %{kind: :fn_clause, index: index},
          children: pattern_nodes ++ guard_nodes ++ [body_node],
          source_span: span_from_meta(clause_meta, file)
        }
      end)

    %Node{
      id: Counter.next(counter),
      type: :fn,
      children: clause_nodes,
      source_span: span_from_meta(meta, file)
    }
  end

  # for comprehension
  defp translate({:for, meta, args}, counter, file) do
    {clauses, opts} = split_for_clauses(args)
    opts = List.flatten(opts)

    clause_nodes =
      Enum.map(clauses, fn
        {:<-, clause_meta, [pattern, enumerable]} ->
          pat_node = translate(pattern, counter, file) |> mark_as_definitions()
          enum_node = translate(enumerable, counter, file)

          %Node{
            id: Counter.next(counter),
            type: :generator,
            children: [pat_node, enum_node],
            source_span: span_from_meta(clause_meta, file)
          }

        {:<<>>, _, [{:<-, clause_meta, [pattern, enumerable]}]} ->
          pat_node = translate(pattern, counter, file)
          enum_node = translate(enumerable, counter, file)

          %Node{
            id: Counter.next(counter),
            type: :generator,
            meta: %{kind: :binary},
            children: [pat_node, enum_node],
            source_span: span_from_meta(clause_meta, file)
          }

        filter_expr ->
          %Node{
            id: Counter.next(counter),
            type: :filter,
            children: [translate(filter_expr, counter, file)]
          }
      end)

    body_node = translate(Keyword.get(opts, :do), counter, file)

    %Node{
      id: Counter.next(counter),
      type: :comprehension,
      meta: Map.new(Keyword.drop(opts, [:do])),
      children: clause_nodes ++ [body_node],
      source_span: span_from_meta(meta, file)
    }
  end

  # Match operator
  defp translate({:=, meta, [left, right]}, counter, file) do
    left_node = translate(left, counter, file) |> mark_as_definitions()
    right_node = translate(right, counter, file)

    %Node{
      id: Counter.next(counter),
      type: :match,
      children: [left_node, right_node],
      source_span: span_from_meta(meta, file)
    }
  end

  # Pin operator
  defp translate({:^, meta, [inner]}, counter, file) do
    inner_node = translate(inner, counter, file)

    %Node{
      id: Counter.next(counter),
      type: :pin,
      children: [inner_node],
      source_span: span_from_meta(meta, file)
    }
  end

  # Tuple literal
  defp translate({:{}, meta, elements}, counter, file) do
    children = Enum.map(elements, &translate(&1, counter, file))

    %Node{
      id: Counter.next(counter),
      type: :tuple,
      children: children,
      source_span: span_from_meta(meta, file)
    }
  end

  # Two-element tuple (special AST form)
  # In Elixir AST, {a, b} is represented as a raw tuple, not {:"{}",...}
  defp translate({left, right}, counter, file) do
    left_node = translate(left, counter, file)
    right_node = translate(right, counter, file)

    %Node{
      id: Counter.next(counter),
      type: :tuple,
      children: [left_node, right_node]
    }
  end

  # Map
  defp translate({:%{}, meta, pairs}, counter, file) do
    children =
      Enum.map(pairs, fn
        {key, value} ->
          translate_map_field(key, value, counter, file)

        # Map update syntax: %{map | key: val}
        {:|, _, [map_expr, updates]} ->
          map_node = translate(map_expr, counter, file)

          update_nodes =
            Enum.map(updates, fn
              {key, value} ->
                key_node = translate(key, counter, file)
                val_node = translate(value, counter, file)

                %Node{
                  id: Counter.next(counter),
                  type: :map_field,
                  meta: %{kind: :update},
                  children: [key_node, val_node]
                }

              other ->
                translate(other, counter, file)
            end)

          %Node{
            id: Counter.next(counter),
            type: :map,
            meta: %{kind: :update},
            children: [map_node | update_nodes]
          }

        other ->
          translate(other, counter, file)
      end)

    %Node{
      id: Counter.next(counter),
      type: :map,
      children: children,
      source_span: span_from_meta(meta, file)
    }
  end

  # Struct
  defp translate({:%, meta, [struct_alias, {:%{}, _, pairs}]}, counter, file) do
    struct_name = module_name(struct_alias)

    children =
      Enum.map(pairs, fn
        {key, value} ->
          translate_map_field(key, value, counter, file)

        other ->
          translate(other, counter, file)
      end)

    %Node{
      id: Counter.next(counter),
      type: :struct,
      meta: %{name: struct_name},
      children: children,
      source_span: span_from_meta(meta, file)
    }
  end

  # Capture operator: &fun/arity
  defp translate({:&, meta, [{:/, _, [{name, _, ctx}, arity]}]}, counter, file)
       when is_atom(name) and is_atom(ctx) and is_integer(arity) do
    %Node{
      id: Counter.next(counter),
      type: :call,
      meta: %{function: name, arity: arity, kind: :fun_ref},
      source_span: span_from_meta(meta, file)
    }
  end

  # Capture operator: &Mod.fun/arity
  defp translate({:&, meta, [{:/, _, [{{:., _, [mod, fun]}, _, _}, arity]}]}, counter, file)
       when is_atom(fun) and is_integer(arity) do
    {_children, resolved} = translate_receiver(mod, counter, file)

    %Node{
      id: Counter.next(counter),
      type: :call,
      meta: %{module: resolved, function: fun, arity: arity, kind: :fun_ref},
      source_span: span_from_meta(meta, file)
    }
  end

  # Capture operator: &(&1 + 1) or &(&1.field) — anonymous function shorthand
  defp translate({:&, meta, [body]}, counter, file) do
    body_node = translate(body, counter, file)

    %Node{
      id: Counter.next(counter),
      type: :fn,
      meta: %{kind: :capture},
      children: [body_node],
      source_span: span_from_meta(meta, file)
    }
  end

  # Binary operators
  @binary_ops [
    :+,
    :-,
    :*,
    :/,
    :++,
    :--,
    :<>,
    :and,
    :or,
    :&&,
    :||,
    :==,
    :!=,
    :===,
    :!==,
    :<,
    :>,
    :<=,
    :>=,
    :in,
    :..,
    :"//"
  ]
  defp translate({op, meta, [left, right]}, counter, file) when op in @binary_ops do
    left_node = translate(left, counter, file)
    right_node = translate(right, counter, file)

    %Node{
      id: Counter.next(counter),
      type: :binary_op,
      meta: %{operator: op},
      children: [left_node, right_node],
      source_span: span_from_meta(meta, file)
    }
  end

  # Unary operators
  @unary_ops [:not, :!, :-, :+, :"^^^"]
  defp translate({op, meta, [operand]}, counter, file) when op in @unary_ops do
    operand_node = translate(operand, counter, file)

    %Node{
      id: Counter.next(counter),
      type: :unary_op,
      meta: %{operator: op},
      children: [operand_node],
      source_span: span_from_meta(meta, file)
    }
  end

  # General function call: local or remote
  defp translate({:., meta, [module, fun_name]}, counter, file) when is_atom(fun_name) do
    {receiver_children, resolved_module} = translate_receiver(module, counter, file)

    %Node{
      id: Counter.next(counter),
      type: :call,
      meta: %{module: resolved_module, function: fun_name, kind: :remote},
      children: receiver_children,
      source_span: span_from_meta(meta, file)
    }
  end

  # Dynamic dispatch: handler.(args) / fun.(args)
  defp translate({{:., meta, [callee]}, call_meta, args}, counter, file)
       when is_list(args) do
    callee_node = translate(callee, counter, file)
    arg_nodes = Enum.map(args, &translate(&1, counter, file))

    %Node{
      id: Counter.next(counter),
      type: :call,
      meta: %{arity: length(args), kind: :dynamic},
      children: [callee_node | arg_nodes],
      source_span: span_from_meta(call_meta || meta, file)
    }
  end

  # Field access: var.field (no parens, no args)
  defp translate({{:., meta, [receiver, field]}, call_meta, []}, counter, file)
       when is_atom(field) and call_meta != [] do
    if call_meta[:no_parens] == true do
      receiver_node = translate(receiver, counter, file)

      %Node{
        id: Counter.next(counter),
        type: :call,
        meta: %{
          module: receiver_var_name(receiver),
          function: field,
          arity: 0,
          kind: :field_access
        },
        children: [receiver_node],
        source_span: span_from_meta(call_meta || meta, file)
      }
    else
      {receiver_children, resolved_module} = translate_receiver(receiver, counter, file)

      %Node{
        id: Counter.next(counter),
        type: :call,
        meta: %{module: resolved_module, function: field, arity: 0, kind: :remote},
        children: receiver_children,
        source_span: span_from_meta(call_meta || meta, file)
      }
    end
  end

  # Quoted code is data, but unquoted expressions execute in the surrounding module.
  defp translate({:quote, meta, args}, counter, file) do
    children =
      args
      |> quoted_body()
      |> unquoted_expressions()
      |> Enum.map(&translate(&1, counter, file))

    %Node{
      id: Counter.next(counter),
      type: :quote,
      meta: %{function: :quote, arity: 1, kind: :macro},
      children: children,
      source_span: span_from_meta(meta, file)
    }
  end

  # Remote call: Module.function(args)
  defp translate({{:., meta, [module, fun_name]}, call_meta, args}, counter, file)
       when is_atom(fun_name) do
    arg_nodes = Enum.map(args, &translate(&1, counter, file))
    {receiver_children, resolved_module} = translate_receiver(module, counter, file)

    %Node{
      id: Counter.next(counter),
      type: :call,
      meta: %{
        module: resolved_module,
        function: fun_name,
        arity: length(args),
        kind: :remote
      },
      children: receiver_children ++ arg_nodes,
      source_span: span_from_meta(call_meta || meta, file)
    }
  end

  # Local call: function(args) — check if imported
  defp translate({fun_name, meta, args}, counter, file)
       when is_atom(fun_name) and is_list(args) do
    arg_nodes = Enum.map(args, &translate(&1, counter, file))
    arity = length(args)

    {module, kind} = resolve_import(fun_name, arity)

    %Node{
      id: Counter.next(counter),
      type: :call,
      meta: %{function: fun_name, arity: arity, module: module, kind: kind},
      children: arg_nodes,
      source_span: span_from_meta(meta, file)
    }
  end

  # Catch-all for unhandled AST forms
  defp translate(ast, counter, _file) do
    %Node{
      id: Counter.next(counter),
      type: :literal,
      meta: %{value: ast, raw: true}
    }
  end

  defp group_function_clauses(%Node{type: :block, children: children} = block) do
    {grouped, order} =
      Enum.reduce(children, {%{}, []}, fn
        %Node{type: :function_def, meta: %{name: name, arity: arity}} = node, {groups, ord} ->
          key = {:func, name, arity}
          groups = Map.update(groups, key, [node], &[node | &1])

          ord =
            if Map.has_key?(groups, key) and length(groups[key]) > 1, do: ord, else: [key | ord]

          {groups, ord}

        node, {groups, ord} ->
          key = {:other, node.id}
          {Map.put(groups, key, [node]), [key | ord]}
      end)

    order = Enum.reverse(order)

    merged =
      Enum.flat_map(order, fn key ->
        case Map.get(grouped, key) do
          [single] ->
            [single]

          [first | _] = defs ->
            all_clauses = defs |> Enum.reverse() |> Enum.flat_map(& &1.children)
            [%{first | children: all_clauses}]
        end
      end)

    %{block | children: merged}
  end

  defp group_function_clauses(node), do: node

  defp translate_module_body(module, body, meta, counter, file) do
    prev_aliases = Process.get(:reach_alias_map, %{})
    prev_imports = Process.get(:reach_import_map, %{})
    prev_module = Process.get(:reach_current_module)

    aliases = collect_aliases(body, module)
    imports = collect_imports(body)

    Process.put(:reach_current_module, module)
    Process.put(:reach_alias_map, Map.merge(prev_aliases, aliases))
    Process.put(:reach_import_map, Map.merge(prev_imports, imports))

    body_node = translate(body, counter, file)
    merged_body = group_function_clauses(body_node)

    Process.put(:reach_current_module, prev_module)
    Process.put(:reach_alias_map, prev_aliases)
    Process.put(:reach_import_map, prev_imports)

    %Node{
      id: Counter.next(counter),
      type: :module_def,
      meta: %{name: module},
      children: [merged_body],
      source_span: span_from_meta(meta, file)
    }
  end

  defp translate_function_def(def_kind, meta, head, guards, body, counter, file) do
    {name, arity} = fun_name_arity(head)
    params = fun_params(head)

    param_nodes =
      Enum.map(params, fn param ->
        param
        |> translate(counter, file)
        |> mark_as_definitions()
      end)

    guard_nodes =
      Enum.map(guards, fn g ->
        %Node{
          id: Counter.next(counter),
          type: :guard,
          children: [translate(g, counter, file)]
        }
      end)

    body_node = translate(body, counter, file)

    clause = %Node{
      id: Counter.next(counter),
      type: :clause,
      meta: %{kind: :function_clause},
      children: param_nodes ++ guard_nodes ++ [body_node]
    }

    %Node{
      id: Counter.next(counter),
      type: :function_def,
      meta: %{
        name: name,
        arity: arity,
        kind: def_kind,
        module: Process.get(:reach_current_module)
      },
      children: [clause],
      source_span: span_from_meta(meta, file)
    }
  end

  defp translate_handler_clauses(nil, _type, _counter, _file), do: []

  defp translate_handler_clauses(clauses, _type, _counter, _file) when not is_list(clauses),
    do: []

  defp translate_handler_clauses(clauses, type, counter, file) do
    Enum.with_index(clauses, fn {:->, clause_meta, [patterns, body]}, index ->
      {pattern_nodes, guard_nodes} = extract_patterns_and_guards(patterns, counter, file)
      body_node = translate(body, counter, file)

      %Node{
        id: Counter.next(counter),
        type: type,
        meta: %{index: index},
        children: pattern_nodes ++ guard_nodes ++ [body_node],
        source_span: span_from_meta(clause_meta, file)
      }
    end)
  end

  defp translate_nullable(nil, counter, _file) do
    %Node{id: Counter.next(counter), type: :literal, meta: %{value: nil}}
  end

  defp translate_nullable(ast, counter, file), do: translate(ast, counter, file)

  defp extract_patterns_and_guards(patterns, counter, file) do
    Enum.reduce(patterns, {[], []}, fn
      {:when, _, [pattern | guards]}, {pats, gs} ->
        pat = translate(pattern, counter, file)

        new_guards =
          Enum.map(guards, fn g ->
            %Node{
              id: Counter.next(counter),
              type: :guard,
              children: [translate(g, counter, file)]
            }
          end)

        {[pat | pats], Enum.reverse(new_guards, gs)}

      pattern, {pats, gs} ->
        {[translate(pattern, counter, file) |> mark_as_definitions() | pats], gs}
    end)
    |> then(fn {pats, gs} -> {Enum.reverse(pats), Enum.reverse(gs)} end)
  end

  defp desugar_pipe(left, {fun, meta, args}) when is_list(args) do
    {fun, meta, [left | args]}
  end

  defp desugar_pipe(left, {fun, meta, nil}) do
    {fun, meta, [left]}
  end

  defp desugar_pipe(left, right) do
    {:__reach_pipe__, [], [left, right]}
  end

  defp quoted_body([opts]) when is_list(opts), do: quoted_body(opts)

  defp quoted_body(args) when is_list(args) do
    case Keyword.fetch(args, :do) do
      {:ok, body} -> body
      :error -> nil
    end
  end

  defp quoted_body(_args), do: nil

  defp unquoted_expressions(nil), do: []

  defp unquoted_expressions(ast) do
    {_ast, expressions} =
      Macro.prewalk(ast, [], fn
        {kind, _meta, [expr]} = node, expressions when kind in [:unquote, :unquote_splicing] ->
          {node, [expr | expressions]}

        node, expressions ->
          {node, expressions}
      end)

    Enum.reverse(expressions)
  end

  defp split_with_clauses(args) do
    Enum.split_while(args, fn
      {:<-, _, _} -> true
      opts when is_list(opts) -> false
      _ -> true
    end)
  end

  defp split_for_clauses(args) do
    Enum.split_while(args, fn
      {:<-, _, _} -> true
      expr when not is_list(expr) -> true
      _ -> false
    end)
  end

  defp fun_name_arity({:when, _, [{name, _, args} | _]}) when is_list(args),
    do: {name, length(args)}

  defp fun_name_arity({name, _, args}) when is_atom(name) and is_list(args),
    do: {name, length(args)}

  defp fun_name_arity({name, _, _}) when is_atom(name), do: {name, 0}
  defp fun_name_arity(_), do: {:__unknown__, 0}

  defp fun_params({:when, _, [{_, _, args} | _]}) when is_list(args), do: args
  defp fun_params({_, _, args}) when is_list(args), do: args
  defp fun_params(_), do: []

  defp receiver_var_name({name, _meta, context}) when is_atom(name) and is_atom(context), do: name
  defp receiver_var_name({{:., _, _}, _, _}), do: nil
  defp receiver_var_name(_), do: nil

  defp translate_receiver({name, _meta, context} = var_ast, counter, file)
       when is_atom(name) and is_atom(context) do
    receiver_node = translate(var_ast, counter, file)
    {[receiver_node], name}
  end

  defp translate_receiver({{:., _, _}, _, _} = call_ast, counter, file) do
    receiver_node = translate(call_ast, counter, file)
    {[receiver_node], nil}
  end

  defp translate_receiver(module, _counter, _file) do
    {[], module_name(module)}
  end

  defp module_name_for_def({:__aliases__, _, parts} = alias_ast) when is_list(parts) do
    cond do
      not Enum.all?(parts, &is_atom/1) ->
        module_name(alias_ast)

      absolute_module_alias?(parts) ->
        module_name(alias_ast)

      parent = Process.get(:reach_current_module) ->
        Module.concat(parent, Module.concat(parts))

      true ->
        module_name(alias_ast)
    end
  end

  defp module_name_for_def(alias_ast), do: module_name(alias_ast)

  defp absolute_module_alias?([Elixir | _]), do: true
  defp absolute_module_alias?(_parts), do: false

  defp module_name({:__aliases__, _, parts}) do
    if Enum.all?(parts, &is_atom/1) do
      raw = Module.concat(parts)
      resolve_alias(raw)
    else
      {:dynamic, parts}
    end
  end

  defp module_name(atom) when is_atom(atom), do: atom
  defp module_name(other), do: other

  defp protocol_impl_module(protocol, _target) when not is_atom(protocol), do: protocol
  defp protocol_impl_module(protocol, nil), do: protocol

  defp protocol_impl_module(protocol, {:__aliases__, _, _} = target) do
    case module_name(target) do
      module when is_atom(module) -> Module.concat(protocol, module)
      _dynamic -> protocol
    end
  end

  defp protocol_impl_module(protocol, target) when is_atom(target) do
    Module.concat(protocol, target)
  rescue
    ArgumentError -> protocol
  end

  defp protocol_impl_module(protocol, _target), do: protocol

  defp resolve_alias(mod) do
    case Process.get(:reach_alias_map, %{}) do
      aliases when map_size(aliases) > 0 -> Map.get(aliases, mod, mod)
      _ -> mod
    end
  end

  defp resolve_import(fun_name, arity) do
    case Process.get(:reach_import_map, %{}) do
      imports when map_size(imports) > 0 ->
        case Map.get(imports, {fun_name, arity}) do
          nil -> {nil, :local}
          module -> {module, :remote}
        end

      _ ->
        {nil, :local}
    end
  end

  defp collect_imports(body) do
    body
    |> extract_import_forms()
    |> Enum.reduce(%{}, fn {module, funs}, acc ->
      Enum.reduce(funs, acc, fn {name, arity}, inner ->
        Map.put_new(inner, {name, arity}, module)
      end)
    end)
  end

  defp extract_import_forms({:__block__, _, exprs}),
    do: Enum.flat_map(exprs, &extract_import_forms/1)

  defp extract_import_forms({:import, _, [{:__aliases__, _, parts}]}) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1) do
      mod = Module.concat(parts)
      [{mod, exported_functions(mod)}]
    else
      []
    end
  end

  defp extract_import_forms({:import, _, [{:__aliases__, _, parts}, opts]})
       when is_list(parts) and is_list(opts) do
    if Enum.all?(parts, &is_atom/1) do
      mod = Module.concat(parts)
      funs = resolve_import_funs(mod, opts)

      [{mod, funs}]
    else
      []
    end
  end

  defp extract_import_forms(_), do: []

  defp exported_functions(mod) do
    if Code.ensure_loaded?(mod) do
      mod.__info__(:functions) ++ mod.__info__(:macros)
    else
      []
    end
  rescue
    _ -> []
  end

  defp exported_of_kind(mod, kind) do
    if Code.ensure_loaded?(mod) do
      mod.__info__(kind)
    else
      []
    end
  rescue
    _ -> []
  end

  defp resolve_import_funs(mod, opts) do
    case Keyword.get(opts, :only) do
      nil -> resolve_import_except(mod, Keyword.get(opts, :except))
      kind when kind in [:macros, :functions] -> exported_of_kind(mod, kind)
      :sigils -> []
      only when is_list(only) -> only
      _ -> []
    end
  end

  defp resolve_import_except(mod, nil), do: exported_functions(mod)
  defp resolve_import_except(mod, except), do: exported_functions(mod) -- except

  defp collect_aliases(body, _current_module) do
    body |> extract_alias_forms() |> Map.new()
  end

  defp extract_alias_forms({:__block__, _, exprs}),
    do: Enum.flat_map(exprs, &extract_alias_forms/1)

  defp extract_alias_forms({:alias, _, [{:__aliases__, _, parts}]}) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1) do
      full = Module.concat(parts)
      short = parts |> List.last() |> then(&Module.concat([&1]))
      [{short, full}]
    else
      []
    end
  end

  defp extract_alias_forms(
         {:alias, _, [{:__aliases__, _, parts}, [as: {:__aliases__, _, as_parts}]]}
       )
       when is_list(parts) and is_list(as_parts) do
    if Enum.all?(parts, &is_atom/1) and Enum.all?(as_parts, &is_atom/1) do
      full = Module.concat(parts)
      short = Module.concat(as_parts)
      [{short, full}]
    else
      []
    end
  end

  # Multi-alias: alias Foo.Bar.{Baz, Qux}
  defp extract_alias_forms(
         {:alias, _, [{{:., _, [{:__aliases__, _, prefix}, :{}]}, _, suffixes}]}
       )
       when is_list(prefix) do
    if Enum.all?(prefix, &is_atom/1) do
      Enum.flat_map(suffixes, fn
        {:__aliases__, _, suffix_parts} when is_list(suffix_parts) ->
          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
          if Enum.all?(suffix_parts, &is_atom/1) do
            full = Module.concat(prefix ++ suffix_parts)
            short = Module.concat(suffix_parts)
            [{short, full}]
          else
            []
          end

        _ ->
          []
      end)
    else
      []
    end
  end

  defp extract_alias_forms(_), do: []

  defp first_child_span(nil), do: nil

  defp first_child_span(%Node{source_span: span}) when span != nil, do: span

  defp first_child_span(%Node{children: children}) do
    Enum.find_value(children, &first_child_span/1)
  end

  defp translate_map_field(key, value, counter, file) do
    key_node = translate(key, counter, file)
    val_node = translate(value, counter, file)

    %Node{
      id: Counter.next(counter),
      type: :map_field,
      children: [key_node, val_node]
    }
  end

  defp span_from_meta(meta, file) when is_list(meta) do
    case meta[:line] do
      nil ->
        nil

      line ->
        %{
          file: file,
          start_line: line,
          start_col: meta[:column] || 1,
          end_line: nil,
          end_col: nil
        }
    end
  end

  defp span_from_meta(_, _), do: nil
end
