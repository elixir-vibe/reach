defmodule Reach.Plugins.LiveView.HEEx.Lowerer do
  @moduledoc false

  alias Reach.Plugins.LiveView.HEEx.Node
  alias Reach.Source.Origin

  def to_ast(%Node.Template{children: children, span: span}) do
    children
    |> lower_children()
    |> block_ast(origin(:template, "HEEx template", span))
  end

  def to_ast(%Node.Text{text: text, span: span}) do
    static_ast(text, span)
  end

  def to_ast(%Node.Expr{ast: ast, code: code, span: span}) do
    put_origin(ast, origin(:expr, label_expr(code, "{}"), span))
  end

  def to_ast(%Node.EExBlock{} = block), do: lower_eex_block(block)

  def to_ast(%Node.Tag{} = tag), do: lower_tag(tag)

  defp lower_children(children) do
    children
    |> Enum.map(&to_ast/1)
    |> Enum.reject(&is_nil/1)
  end

  defp lower_eex_block(%Node.EExBlock{
         head_ast: {:if, meta, [condition, _]},
         clauses: clauses,
         head_code: code,
         span: span
       }) do
    {do_ast, else_ast} = if_clauses(clauses)

    {:if, put_origin_meta(meta, origin(:if, label_eex(code), span)),
     [condition, [do: do_ast, else: else_ast]]}
  end

  defp lower_eex_block(%Node.EExBlock{
         head_ast: {:case, meta, [expr, _]},
         clauses: clauses,
         head_code: code,
         span: span
       }) do
    clause_asts = Enum.map(clauses, &case_clause_ast/1) |> Enum.reject(&is_nil/1)

    {:case, put_origin_meta(meta, origin(:case, label_eex(code), span)),
     [expr, [do: clause_asts]]}
  end

  defp lower_eex_block(%Node.EExBlock{clauses: clauses, head_code: code, span: span}) do
    clauses
    |> Enum.flat_map(& &1.children)
    |> lower_children()
    |> block_ast(origin(:eex_block, label_eex(code), span))
  end

  defp if_clauses([
         %Node.EExClause{children: do_children},
         %Node.EExClause{children: else_children} | _
       ]) do
    {block_ast(lower_children(do_children), nil), block_ast(lower_children(else_children), nil)}
  end

  defp if_clauses([%Node.EExClause{children: do_children} | _]) do
    {block_ast(lower_children(do_children), nil), nil}
  end

  defp if_clauses(_), do: {nil, nil}

  defp case_clause_ast(%Node.EExClause{code: "end"}), do: nil

  defp case_clause_ast(%Node.EExClause{code: code, children: children, span: span}) do
    [pattern_code | _] = String.split(code, "->", parts: 2)

    patterns =
      pattern_code
      |> String.trim()
      |> parse_patterns(span)

    {:->, meta_from_span(span), [patterns, block_ast(lower_children(children), nil)]}
  end

  defp lower_tag(%Node.Tag{} = tag) do
    ast = lower_tag_body(tag)

    tag.special
    |> Enum.reverse()
    |> Enum.reduce(ast, fn
      %Node.SpecialAttr{name: :if, ast: condition, span: span, code: code}, inner ->
        {:if, meta_from_span(span, origin(:if, ":if #{code}", span)), [condition, [do: inner]]}

      %Node.SpecialAttr{name: :for, ast: {:<-, meta, args}, span: span, code: code}, inner ->
        {:for, put_origin_meta(meta, origin(:for, ":for #{code}", span)),
         [{:<-, put_origin_meta(meta, origin(:for, ":for #{code}", span)), args}, [do: inner]]}

      %Node.SpecialAttr{name: :for, ast: for_ast, span: span, code: code}, inner ->
        {:for, meta_from_span(span, origin(:for, ":for #{code}", span)), [for_ast, [do: inner]]}

      _special, inner ->
        inner
    end)
  end

  defp lower_tag_body(%Node.Tag{
         type: type,
         name: name,
         attrs: attrs,
         children: children,
         open_span: span
       })
       when type in [:local_component, :remote_component] do
    args = [assigns_map(attrs, children)]
    call = component_call(type, name, args, span)
    put_origin(call, origin(:component, component_label(type, name), span))
  end

  defp lower_tag_body(%Node.Tag{type: :slot, name: name, children: children, open_span: span}) do
    block_ast(lower_children(children), origin(:slot, "<:#{name}>", span))
  end

  defp lower_tag_body(%Node.Tag{name: name, attrs: attrs, children: children, open_span: span}) do
    event_attrs = event_attr_asts(attrs)
    dynamic_attrs = dynamic_attr_asts(attrs)
    body = lower_children(children)
    parts = event_attrs ++ dynamic_attrs ++ body

    case parts do
      [] -> static_ast("<#{name}>", span)
      _ -> block_ast(parts, origin(:tag, "<#{name}>", span))
    end
  end

  defp assigns_map(attrs, children) do
    fields =
      attrs
      |> Enum.reject(&match?(%Node.SpecialAttr{}, &1))
      |> Enum.flat_map(&attr_field/1)

    inner = lower_children(children)
    fields = if inner == [], do: fields, else: [{:inner_block, block_ast(inner, nil)} | fields]
    {:%{}, [], fields}
  end

  defp attr_field(%Node.Attr{name: name, value: {:expr, _code, ast}}),
    do: [{source_atom(name), ast}]

  defp attr_field(%Node.Attr{name: name, value: {:string, value}}),
    do: [{source_atom(name), value}]

  defp attr_field(_), do: []

  @event_attrs ~w(phx-click phx-submit phx-change phx-keyup phx-keydown phx-blur phx-focus phx-window-keyup phx-window-keydown)

  defp event_attr_asts(attrs) do
    attrs
    |> Enum.flat_map(fn
      %Node.Attr{name: name, value: {:string, event}, span: span} when name in @event_attrs ->
        [event_call(name, event, span)]

      %Node.Attr{name: name, value: {:expr, _code, ast}, span: span} when name in @event_attrs ->
        [put_origin(ast, origin(:event, name, span))]

      _ ->
        []
    end)
  end

  defp event_call(name, event, span) do
    meta = meta_from_span(span, origin(:event, "#{name}=#{inspect(event)}", span))
    {:__live_event__, meta, [event]}
  end

  defp dynamic_attr_asts(attrs) do
    attrs
    |> Enum.reject(fn
      %Node.SpecialAttr{} -> true
      %Node.Attr{name: name} -> name in @event_attrs
      _ -> false
    end)
    |> Enum.flat_map(fn
      %Node.Attr{value: {:expr, _code, ast}, span: span, name: name} ->
        [put_origin(ast, origin(:attr, name, span))]

      _ ->
        []
    end)
  end

  defp component_label(:local_component, name), do: "<.#{name}>"
  defp component_label(:remote_component, name), do: "<#{name}>"

  defp component_call(:local_component, name, args, span) do
    {source_atom(name), meta_from_span(span), args}
  end

  defp component_call(:remote_component, name, args, span) do
    case remote_component_parts(name) do
      {mod, fun} -> {{:., meta_from_span(span), [mod, fun]}, meta_from_span(span), args}
      nil -> {source_atom(name), meta_from_span(span), args}
    end
  end

  defp remote_component_parts(name) do
    case String.split(name, ".") do
      [_] ->
        nil

      parts ->
        {fun, mod_parts} = List.pop_at(parts, -1)
        {{:__aliases__, [], Enum.map(mod_parts, &source_atom/1)}, source_atom(fun)}
    end
  end

  defp source_atom(name) when is_binary(name), do: :erlang.binary_to_atom(name, :utf8)

  defp block_ast([], _origin), do: nil
  defp block_ast([single], nil), do: single
  defp block_ast([single], %Origin{} = origin), do: put_origin(single, origin)
  defp block_ast(parts, nil), do: {:__block__, [], parts}
  defp block_ast(parts, %Origin{} = origin), do: {:__block__, [reach: origin], parts}

  defp static_ast(text, span) do
    label = text |> to_string() |> String.trim() |> String.slice(0, 100)

    {:__block__, [reach: origin(:static, if(label == "", do: "static HEEx", else: label), span)],
     [:heex_static]}
  end

  defp put_origin({form, meta, args}, %Origin{} = origin) when is_list(meta) and is_list(args) do
    {form, put_origin_meta(meta, origin), args}
  end

  defp put_origin(other, _origin), do: other

  defp put_origin_meta(meta, %Origin{} = origin),
    do: Keyword.put_new(meta || [], Reach.Source.metadata_key(), origin)

  defp origin(kind, label, span) do
    %Origin{
      language: :heex,
      kind: kind,
      label: label,
      span: span,
      plugin: Reach.Plugins.LiveView,
      generated?: true
    }
  end

  defp meta_from_span(span, origin \\ nil)

  defp meta_from_span(%{start_line: line, start_col: col}, nil),
    do: [line: line, column: col || 1]

  defp meta_from_span(%{start_line: line, start_col: col}, %Origin{} = origin),
    do: [line: line, column: col || 1, reach: origin]

  defp meta_from_span(_, nil), do: []
  defp meta_from_span(_, %Origin{} = origin), do: [reach: origin]

  defp parse_patterns(code, span) do
    code = String.trim(code)

    case Code.string_to_quoted("[" <> code <> "]",
           line: span_line(span),
           column: span_col(span),
           columns: true
         ) do
      {:ok, list} -> list_values(list)
      _ -> [Macro.var(:_, nil)]
    end
  end

  defp list_values({:__block__, _, [list]}), do: list_values(list)
  defp list_values(list) when is_list(list), do: list
  defp list_values(other), do: [other]

  defp span_line(%{start_line: line}) when is_integer(line), do: line
  defp span_line(_), do: 1
  defp span_col(%{start_col: col}) when is_integer(col), do: col
  defp span_col(_), do: 1

  defp label_eex(code), do: "<%= #{String.trim(code)} %>"
  defp label_expr(code, wrapper), do: String.replace(wrapper, "{}", "{#{String.trim(code)}}")
end
