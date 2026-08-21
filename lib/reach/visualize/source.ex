defmodule Reach.Visualize.Source do
  @moduledoc "Extracts and highlights source code snippets for blocks."

  alias Reach.Frontend.Gleam

  @def_cache_key :reach_def_end_cache
  @fallback_function_line_span 50
  @source_extensions Reach.Frontend.source_extensions()

  def ensure_def_cache(file) do
    cache = Process.get(@def_cache_key, %{})

    unless Map.has_key?(cache, file) do
      line_map = build_def_line_map(file)
      Process.put(@def_cache_key, Map.put(cache, file, line_map))
    end
  end

  def extract_func_source(%{type: :function_def, meta: %{source: source, language: :javascript}})
      when is_binary(source) do
    source
  end

  def extract_func_source(%{type: :function_def, source_span: %{file: file, start_line: start}})
      when is_binary(file) and is_integer(start) do
    with end_line when is_integer(end_line) <- find_end_line(file, start),
         {:ok, content} <- File.read(file) do
      content
      |> String.split("\n")
      |> Enum.slice((start - 1)..(end_line - 1))
      |> Enum.join("\n")
      |> format_source()
    else
      _ -> nil
    end
  end

  def extract_func_source(_), do: nil

  def highlight_source(nil), do: nil
  def highlight_source(source), do: highlight_source(source, :elixir)

  def highlight_source(nil, _), do: nil

  def highlight_source(source, lang) do
    if Code.ensure_loaded?(Makeup) do
      Makeup.highlight_inner_html(source, lexer_opts(lang))
    else
      nil
    end
  end

  def format_source(source) do
    Code.format_string!(source) |> IO.iodata_to_binary()
  rescue
    _error in [SyntaxError, TokenMissingError] -> String.trim(source)
  end

  def highlight_line(file, line) when is_binary(file) and is_integer(line) do
    case read_line(file, line) do
      nil ->
        nil

      text ->
        source = String.trim_leading(text)
        highlight_source(source, lang_for_file(file)) || escape_html(source)
    end
  end

  def highlight_line(_, _), do: nil

  def highlight_lines(file, from, to) when is_binary(file) do
    case cached_file_lines(file) do
      nil ->
        nil

      lines ->
        lines
        |> Enum.slice((from - 1)..max(from - 1, to - 1))
        |> dedent()
        |> Enum.join("\n")
        |> highlight_source(lang_for_file(file))
    end
  end

  def highlight_lines(_, _, _), do: nil

  def dedent(lines) do
    min_indent =
      lines
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.map(fn line -> byte_size(line) - byte_size(String.trim_leading(line)) end)
      |> Enum.min(fn -> 0 end)

    Enum.map(lines, fn line -> String.slice(line, min_indent, byte_size(line)) end)
  end

  def read_line(file, line) do
    case cached_file_lines(file) do
      nil -> nil
      lines -> Enum.at(lines, line - 1)
    end
  end

  def cached_file_lines(file) do
    case Process.get({:reach_file_lines, file}) do
      nil -> if source_file?(file), do: do_cached_file_lines(file), else: nil
      lines -> lines
    end
  end

  def extract_clause_source(func, clause, all_clauses, file) do
    clause_start = span_field(clause, :start_line) || min_child_line(clause)

    with true <- is_binary(file) and is_integer(clause_start),
         end_line <- clause_end_line(func, clause_start, all_clauses, file),
         true <- is_integer(end_line) and end_line >= clause_start do
      case cached_file_lines(file) do
        nil ->
          nil

        lines ->
          lines
          |> Enum.slice((clause_start - 1)..(end_line - 1))
          |> dedent()
          |> Enum.join("\n")
          |> format_source()
      end
    else
      _ -> nil
    end
  end

  def min_line_in_subtree(node) do
    line = span_field(node, :start_line)
    child_lines = Enum.flat_map(node.children, &collect_lines/1)
    all = if line, do: [line | child_lines], else: child_lines
    Enum.min(all, fn -> nil end)
  end

  def clause_end_line(func, clause_start, all_clauses, file) do
    next_start =
      all_clauses
      |> Enum.map(&(span_field(&1, :start_line) || min_child_line(&1) || 0))
      |> Enum.filter(&(&1 > clause_start))
      |> Enum.min(fn -> nil end)

    (next_start && next_start - 1) || func_end_line(func, file)
  end

  def func_end_line(func, file) do
    case span_field(func, :end_line) do
      end_line when is_integer(end_line) ->
        end_line

      _ ->
        if file, do: ensure_def_cache(file)
        start = span_field(func, :start_line)
        fallback = file_line_count(file) || (start || 1) + @fallback_function_line_span
        line_map = Process.get(@def_cache_key, %{}) |> Map.get(file, %{})
        Map.get(line_map, start) || find_nearest_end(line_map, start) || fallback
    end
  end

  def span_field(%{source_span: %{} = span}, field), do: Map.get(span, field)
  def span_field(_, _), do: nil

  def source_file?(nil), do: false
  def source_file?(file), do: Path.extname(file) in @source_extensions

  defp escape_html(source) do
    source
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp lexer_opts(:javascript) do
    if Code.ensure_loaded?(Makeup.Lexers.JsLexer) do
      [lexer: Makeup.Lexers.JsLexer]
    else
      []
    end
  end

  defp lexer_opts(_), do: []

  defp lang_for_file(file) when is_binary(file) do
    case Process.get({:reach_file_lang, file}) do
      nil -> Reach.Frontend.language_from_path(file)
      lang -> lang
    end
  end

  defp do_cached_file_lines(file) do
    cache_key = {:reach_file_lines, file}

    case Process.get(cache_key) do
      nil ->
        with {:ok, content} <- File.read(file),
             true <- String.valid?(content) do
          lines = String.split(content, "\n")
          Process.put(cache_key, lines)
          lines
        else
          _ -> nil
        end

      lines ->
        lines
    end
  end

  defp min_child_line(node) do
    node.children
    |> Enum.flat_map(&collect_lines/1)
    |> Enum.min(fn -> nil end)
  end

  defp collect_lines(node) do
    line = span_field(node, :start_line)
    child_lines = Enum.flat_map(node.children, &collect_lines/1)
    if line, do: [line | child_lines], else: child_lines
  end

  defp find_end_line(file, start_line) do
    cache = Process.get(@def_cache_key, %{})

    case Map.get(cache, file) do
      nil ->
        line_map = build_def_line_map(file)
        Process.put(@def_cache_key, Map.put(cache, file, line_map))
        Map.get(line_map, start_line)

      line_map ->
        Map.get(line_map, start_line)
    end
  end

  defp build_def_line_map(file) do
    cond do
      String.ends_with?(file, ".gleam") ->
        build_gleam_def_map(file)

      not source_file?(file) ->
        %{}

      true ->
        with {:ok, source} <- File.read(file),
             true <- String.valid?(source),
             {:ok, ast} <-
               Code.string_to_quoted(source,
                 columns: true,
                 token_metadata: true,
                 emit_warnings: false,
                 file: file
               ) do
          collect_def_ranges(ast)
        else
          _ -> %{}
        end
    end
  end

  defp build_gleam_def_map(file) do
    with {:ok, source} <- File.read(file),
         {:ok, {:module, _, _, _, _, functions}} <- call_glance(source) do
      offsets = Gleam.build_line_offsets(source)

      Map.new(functions, fn {:definition, _, {:function, {:span, s, e}, _, _, _, _, _}} ->
        start_line = Gleam.byte_to_line(offsets, s)
        end_line = Gleam.byte_to_line(offsets, max(e - 1, s))
        {start_line, end_line}
      end)
    else
      _ -> %{}
    end
  end

  defp call_glance(source) do
    if :code.which(:glance) == :non_existing do
      for path <- Path.wildcard("/tmp/glance/build/dev/erlang/*/ebin"),
          do: :code.add_patha(to_charlist(path))
    end

    if :code.which(:glance) != :non_existing do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(:glance, :module, [source])
    else
      {:error, :glance_not_available}
    end
  end

  defp collect_def_ranges(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, %{}, fn
        {kind, meta, _args} = node, acc when kind in [:def, :defp, :defmacro, :defmacrop] ->
          start_line = meta[:line]
          end_line = meta[:end_of_expression][:line] || meta[:closing][:line]
          acc = if start_line && end_line, do: Map.put(acc, start_line, end_line), else: acc
          {node, acc}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp find_nearest_end(line_map, start) when is_integer(start) do
    for({k, _v} <- line_map, k <= start, do: k)
    |> Enum.max(fn -> nil end)
    |> then(fn nearest -> if nearest, do: Map.get(line_map, nearest) end)
  end

  defp find_nearest_end(_, _), do: nil

  defp file_line_count(nil), do: nil

  defp file_line_count(file) do
    case cached_file_lines(file) do
      nil -> nil
      lines -> length(lines)
    end
  end
end
