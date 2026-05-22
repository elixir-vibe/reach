defmodule Reach.Plugins.LiveView.HEEx do
  @moduledoc false

  alias Reach.Frontend.Elixir, as: ElixirFrontend
  alias Reach.IR.Counter
  alias Reach.Plugins.LiveView.HEEx.{Lowerer, Parser}
  alias Reach.Source.{Origin, Span}

  @tag_engine Phoenix.LiveView.TagEngine
  @html_engine Phoenix.LiveView.HTMLEngine
  @engine Reach.Plugins.LiveView.HEExEngine

  def lower_sigil(source, meta, opts) when is_binary(source) and is_list(meta) do
    with :ok <- ensure_available(),
         line = (meta[:line] || 1) + 1,
         file = opts[:file],
         {:ok, ast} <- lower_template(source, sigil_options(source, meta, opts), file, line) do
      {:ok, put_origin(ast, :sigil, "~H", Span.from_meta(meta, file))}
    else
      :error -> {:error, :live_view_not_available}
      {:error, _} = error -> error
    end
  end

  def parse_file(path, opts) do
    with :ok <- ensure_available(),
         {:ok, source} <- File.read(path),
         {:ok, ast} <- lower_template(source, file_options(source, path, opts), path, 1) do
      module = Keyword.get(opts, :module) || module_from_path(path)
      wrapper = wrap_render(module, ast, path)
      counter = Keyword.get_lazy(opts, :counter, &Counter.new/0)
      {:ok, ElixirFrontend.translate_ast(wrapper, counter, path)}
    else
      {:error, _} = error -> error
      :error -> {:error, :live_view_not_available}
    end
  end

  defp ensure_available do
    if Code.ensure_loaded?(@tag_engine) and Code.ensure_loaded?(@html_engine) do
      :ok
    else
      :error
    end
  end

  defp lower_template(source, opts, file, first_line) do
    parser_opts = Keyword.merge(opts, file: file, line: first_line)

    case Parser.parse(source, parser_opts) do
      {:ok, template} ->
        {:ok, Lowerer.to_ast(template)}

      {:error, :live_view_parser_not_available} ->
        compile_with_live_view(source, opts, file, first_line)

      {:error, _reason} = error ->
        error
    end
  end

  defp compile_with_live_view(source, opts, file, first_line) do
    opts = opts |> Keyword.put(:engine, @tag_engine) |> Keyword.put(:subengine, @engine)

    with {:ok, ast} <- compile(source, opts) do
      {:ok, annotate_template_ast(ast, source, file, first_line)}
    end
  end

  defp compile(source, opts) do
    {:ok, EEx.compile_string(source, opts)}
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp sigil_options(source, meta, opts) do
    file = Keyword.get(opts, :file, "nofile")

    [
      engine: @engine,
      file: file,
      line: (meta[:line] || 1) + 1,
      caller: caller(file, opts[:module]),
      indentation: meta[:indentation] || 0,
      source: source,
      tag_handler: @html_engine
    ]
  end

  defp file_options(source, path, opts) do
    [
      engine: @engine,
      file: path,
      line: 1,
      caller: caller(path, opts[:module]),
      indentation: 0,
      source: source,
      tag_handler: @html_engine
    ]
  end

  defp caller(file, module) do
    env =
      if function_exported?(Code, :env_for_eval, 1) do
        Code.env_for_eval(file: file)
      else
        %{__ENV__ | file: file}
      end

    %{env | module: module}
  end

  defp annotate_template_ast(ast, source, file, first_line) do
    lines = String.split(source, "\n", trim: false)

    Macro.postwalk(ast, fn
      {form, meta, args} = node when is_list(meta) and is_list(args) ->
        case template_origin(form, meta, args, lines, file, first_line) do
          nil -> node
          origin -> put_origin(node, origin)
        end

      other ->
        other
    end)
  end

  defp template_origin(form, meta, _args, lines, file, first_line)
       when form in [:if, :case, :cond, :for, :with] do
    origin_from_meta(meta, form, lines, file, first_line)
  end

  defp template_origin(:<-, meta, _args, lines, file, first_line) do
    origin_from_meta(meta, :for, lines, file, first_line)
  end

  defp template_origin(
         {:., _dot_meta, [{:__aliases__, _, [:Phoenix, :LiveView, :TagEngine]}, fun]},
         meta,
         _args,
         lines,
         file,
         first_line
       )
       when fun in [:component, :inner_block] do
    origin_from_meta(meta, fun, lines, file, first_line)
  end

  defp template_origin(_form, _meta, _args, _lines, _file, _first_line), do: nil

  defp origin_from_meta(meta, kind, lines, file, first_line) do
    case meta[:line] do
      line when is_integer(line) ->
        %Origin{
          language: :heex,
          kind: kind,
          label: line_label(lines, line, first_line, kind),
          span: %Span{file: file, start_line: line, start_col: meta[:column] || 1},
          plugin: Reach.Plugins.LiveView,
          generated?: true
        }

      _ ->
        nil
    end
  end

  defp line_label(lines, line, first_line, fallback) do
    lines
    |> Enum.at(line - first_line)
    |> case do
      nil -> to_string(fallback)
      text -> text |> String.trim() |> blank_fallback(fallback) |> String.slice(0, 100)
    end
  end

  defp blank_fallback("", fallback), do: to_string(fallback)
  defp blank_fallback(text, _fallback), do: text

  defp put_origin({form, meta, args} = ast, %Origin{} = origin)
       when is_list(meta) and is_list(args) do
    if Keyword.has_key?(meta, Reach.Source.metadata_key()) do
      ast
    else
      {form, Keyword.put(meta, Reach.Source.metadata_key(), origin), args}
    end
  end

  defp put_origin(ast, %Origin{}), do: ast

  defp put_origin(ast, kind, label, span) do
    put_origin(ast, %Origin{
      language: :heex,
      kind: kind,
      label: label,
      span: span,
      plugin: Reach.Plugins.LiveView,
      generated?: true
    })
  end

  defp wrap_render(module, ast, path) do
    quote generated: true, line: 1 do
      defmodule unquote(module) do
        def render(assigns) do
          unquote(
            put_origin(ast, :file, Path.basename(path), %Span{
              file: path,
              start_line: 1,
              start_col: 1
            })
          )
        end
      end
    end
  end

  defp module_from_path(path) do
    path
    |> Path.relative_to_cwd()
    |> strip_extensions()
    |> Path.split()
    |> Enum.reject(&(&1 in [".", "/", ""]))
    |> Enum.map(&module_segment/1)
    |> then(fn
      [] -> ["Template"]
      segments -> segments
    end)
    |> then(&Module.concat([Reach.Templates | &1]))
  end

  defp strip_extensions(path) do
    path
    |> Path.rootname()
    |> Path.rootname()
  end

  defp module_segment(segment) do
    segment
    |> String.replace(~r/[^A-Za-z0-9_]/, "_")
    |> Macro.camelize()
  end
end
