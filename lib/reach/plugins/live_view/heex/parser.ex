defmodule Reach.Plugins.LiveView.HEEx.Parser do
  @moduledoc false

  alias Reach.Plugins.LiveView.HEEx.Node
  alias Reach.Source.Span

  @parser Phoenix.LiveView.TagEngine.Parser
  @html_engine Phoenix.LiveView.HTMLEngine

  def parse(source, opts) when is_binary(source) do
    with :ok <- ensure_parser(),
         {:ok, parsed} <- parse_with_live_view(source, opts) do
      previous_file = Process.get(:reach_heex_file)
      Process.put(:reach_heex_file, Keyword.get(opts, :file))

      try do
        {:ok,
         %Node.Template{
           children: normalize_nodes(parsed.nodes),
           span: template_span(source, opts)
         }}
      after
        restore_process_value(:reach_heex_file, previous_file)
      end
    end
  end

  defp ensure_parser do
    if Code.ensure_loaded?(@parser) and function_exported?(@parser, :parse, 2) do
      :ok
    else
      {:error, :live_view_parser_not_available}
    end
  end

  defp parse_with_live_view(source, opts) do
    parser_opts = [
      file: Keyword.get(opts, :file, "nofile"),
      line: Keyword.get(opts, :line, 1),
      caller: Keyword.get(opts, :caller),
      indentation: Keyword.get(opts, :indentation, 0),
      tag_handler: @html_engine,
      skip_macro_components: true
    ]

    case :erlang.apply(@parser, :parse, [source, parser_opts]) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, line, column, message} -> {:error, {line, column, message}}
      other -> {:error, other}
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp normalize_nodes(nodes), do: Enum.map(nodes, &normalize_node/1)

  defp normalize_node({:text, text, meta}) do
    %Node.Text{text: text, span: span(meta)}
  end

  defp normalize_node({:body_expr, code, meta}) do
    %Node.Expr{marker: "=", code: code, ast: parse_expr(code, meta), span: span(meta)}
  end

  defp normalize_node({:eex, code, meta}) do
    %Node.Expr{
      marker: meta |> Map.get(:opt, "") |> to_string(),
      code: code,
      ast: parse_expr(code, meta),
      span: span(meta)
    }
  end

  defp normalize_node({:eex_comment, text}), do: %Node.Text{text: text, span: nil}

  defp normalize_node({:eex_block, code, clauses, meta}) do
    %Node.EExBlock{
      marker: meta |> Map.get(:opt, "") |> to_string(),
      head_code: code,
      head_ast: parse_block_head(code, meta),
      clauses: Enum.map(clauses, &normalize_clause/1),
      span: span(meta)
    }
  end

  defp normalize_node({:block, type, name, attrs, children, open_meta, close_meta}) do
    attrs = normalize_attrs(attrs)

    %Node.Tag{
      type: type,
      name: name,
      attrs: attrs,
      special: special_attrs(attrs),
      children: normalize_nodes(children),
      open_span: span(open_meta),
      close_span: span(close_meta),
      span: merge_spans(span(open_meta), span(close_meta))
    }
  end

  defp normalize_node({:self_close, type, name, attrs, meta}) do
    attrs = normalize_attrs(attrs)

    %Node.Tag{
      type: type,
      name: name,
      attrs: attrs,
      special: special_attrs(attrs),
      children: [],
      open_span: span(meta),
      close_span: span(meta),
      span: span(meta)
    }
  end

  defp normalize_node(other), do: %Node.Text{text: inspect(other), span: nil}

  defp normalize_clause({children, code, meta}) do
    %Node.EExClause{
      code: code,
      ast: parse_clause(code, meta),
      children: normalize_nodes(children),
      span: span(meta)
    }
  end

  defp normalize_attrs(attrs), do: Enum.map(attrs, &normalize_attr/1)

  defp normalize_attr({name, {:expr, code, expr_meta}, meta})
       when name in [":if", ":for", ":key"] do
    %Node.SpecialAttr{
      name: name |> String.trim_leading(":") |> source_atom(),
      code: code,
      ast: parse_expr(code, expr_meta),
      span: span(meta)
    }
  end

  defp normalize_attr({name, {:expr, code, expr_meta}, meta}) do
    %Node.Attr{name: name, value: {:expr, code, parse_expr(code, expr_meta)}, span: span(meta)}
  end

  defp normalize_attr({name, {:string, value, _value_meta}, meta}) do
    %Node.Attr{name: name, value: {:string, value}, span: span(meta)}
  end

  defp normalize_attr({name, value, meta}) do
    %Node.Attr{name: name, value: value, span: span(meta)}
  end

  defp special_attrs(attrs), do: Enum.filter(attrs, &match?(%Node.SpecialAttr{}, &1))

  defp source_atom(name) when is_binary(name), do: :erlang.binary_to_atom(name, :utf8)

  defp parse_expr(code, meta) do
    Code.string_to_quoted!(code, line: meta_line(meta), column: meta_column(meta), columns: true)
  rescue
    _ -> code
  end

  defp parse_block_head(code, meta) do
    trimmed = String.trim(code)

    cond do
      String.starts_with?(trimmed, "if ") or String.starts_with?(trimmed, "unless ") ->
        parse_expr(trimmed <> "\n nil\nend", meta)

      String.starts_with?(trimmed, "case ") and String.ends_with?(trimmed, " do") ->
        expr = trimmed |> String.trim_leading("case ") |> String.trim_trailing(" do")
        {:case, meta_list(meta), [parse_expr(expr, meta), [do: []]]}

      String.starts_with?(trimmed, "cond do") ->
        {:cond, meta_list(meta), [[do: []]]}

      true ->
        parse_expr(trimmed, meta)
    end
  end

  defp parse_clause("end", _meta), do: :end

  defp parse_clause(code, meta),
    do: parse_expr("case :__reach__ do\n" <> code <> " :__reach_clause__\nend", meta)

  defp span(meta) when is_map(meta) do
    %Span{
      file: Map.get(meta, :file) || Process.get(:reach_heex_file),
      start_line: Map.get(meta, :line),
      start_col: Map.get(meta, :column),
      end_line: Map.get(meta, :line_end),
      end_col: Map.get(meta, :column_end)
    }
  end

  defp span(_), do: nil

  defp template_span(source, opts) do
    first_line = Keyword.get(opts, :line, 1)
    line_count = max(length(String.split(source, "\n", trim: false)) - 1, 0)

    %Span{
      file: Keyword.get(opts, :file),
      start_line: first_line,
      start_col: 1,
      end_line: first_line + line_count,
      end_col: nil
    }
  end

  defp merge_spans(%Span{} = first, %Span{} = last),
    do: %{
      first
      | end_line: last.end_line || last.start_line,
        end_col: last.end_col || last.start_col
    }

  defp merge_spans(first, _), do: first

  defp meta_list(meta), do: [line: meta_line(meta), column: meta_column(meta)]

  defp restore_process_value(key, nil), do: Process.delete(key)
  defp restore_process_value(key, value), do: Process.put(key, value)

  defp meta_line(meta) when is_map(meta), do: Map.get(meta, :line, 1)
  defp meta_line(_), do: 1
  defp meta_column(meta) when is_map(meta), do: Map.get(meta, :column, 1)
  defp meta_column(_), do: 1
end
