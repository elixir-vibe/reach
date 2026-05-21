defmodule Reach.Evidence.StandardLibraryBypass.PathURI do
  @moduledoc "Collects Path/URI standard-library bypass evidence."

  import ExAST.Sigil

  alias Reach.Evidence.PatternRunner

  @path_names ~w(path filepath file_path filename file dir directory source dest destination)a
  @uri_names ~w(url uri href endpoint query query_string qs)a

  @pattern_evidence [
    path_basename:
      {~p[_ |> String.split("/") |> List.last()], :path_pipe, :manual_path_basename,
       "manual path basename extraction; use Path.basename/1", "Path.basename/1"},
    path_extension:
      {~p[_ |> String.split(".") |> List.last()], :path_pipe, :manual_path_extension,
       "manual path extension extraction; use Path.extname/1 and normalize the leading dot when needed",
       "Path.extname/1"},
    uri_path_split:
      {~p[_ |> String.split("?") |> List.first()], :uri_pipe, :manual_uri_path_split,
       "manual URL splitting; use URI.parse/1", "URI.parse/1"},
    query_parsing:
      {~p[String.split(_, "&")], :uri_direct, :manual_query_parsing,
       "manual query-string splitting; use URI.decode_query/1", "URI.decode_query/1"},
    uri_scheme_split:
      {~p[String.split(_, "://")], :uri_direct, :manual_uri_scheme_split,
       "manual URL scheme splitting; use URI.parse/1", "URI.parse/1"}
  ]

  def collect_ast(ast), do: PatternRunner.run(ast, pattern_specs(), family: :stdlib)

  def kinds do
    [
      :manual_path_basename,
      :manual_path_extension,
      :manual_query_parsing,
      :manual_uri_path_split,
      :manual_uri_scheme_split
    ]
  end

  defp pattern_specs do
    Enum.map(@pattern_evidence, fn {name, {pattern, mode, kind, message, replacement}} ->
      {name, {pattern, &build_evidence(&1, mode, kind, message, replacement)}}
    end)
  end

  defp build_evidence(match, :path_pipe, kind, message, replacement) do
    with {:ok, subject} <- pipe_split_subject(match.node),
         true <- path_subject?(subject) do
      evidence(kind, message, replacement)
    else
      _other -> nil
    end
  end

  defp build_evidence(match, :uri_pipe, kind, message, replacement) do
    with {:ok, subject} <- pipe_split_subject(match.node),
         true <- uri_subject?(subject) do
      evidence(kind, message, replacement)
    else
      _other -> nil
    end
  end

  defp build_evidence(match, :uri_direct, kind, message, replacement) do
    with {:ok, subject} <- direct_split_subject(match.node),
         true <- uri_subject?(subject) do
      evidence(kind, message, replacement)
    else
      _other -> nil
    end
  end

  defp pipe_split_subject({:|>, _, [{:|>, _, [subject, _split_call]}, _reader]}),
    do: {:ok, subject}

  defp pipe_split_subject(
         {:|>, _,
          [{{:., _, [{:__aliases__, _, [:String]}, :split]}, _, [subject, _delimiter]}, _reader]}
       ),
       do: {:ok, subject}

  defp pipe_split_subject(_node), do: :error

  defp direct_split_subject(
         {{:., _, [{:__aliases__, _, [:String]}, :split]}, _, [subject, _delimiter]}
       ),
       do: {:ok, subject}

  defp direct_split_subject(_node), do: :error

  defp evidence(kind, message, replacement) do
    %{kind: kind, message: message, replacement: replacement, confidence: :high}
  end

  defp path_subject?(subject), do: subject_name(subject) in @path_names
  defp uri_subject?(subject), do: subject_name(subject) in @uri_names

  defp subject_name({name, _meta, context}) when is_atom(name) and is_atom(context), do: name
  defp subject_name(_), do: nil
end
