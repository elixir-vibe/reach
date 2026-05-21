defmodule Reach.Evidence.StandardLibraryBypass.PathURI do
  @moduledoc "Collects Path/URI standard-library bypass evidence."

  alias Reach.Evidence.StandardLibraryBypass.Evidence

  @path_names ~w(path filepath file_path filename file dir directory source dest destination)a
  @uri_names ~w(url uri href endpoint query query_string qs)a

  def collect_ast(ast) do
    {_ast, evidence} = Macro.prewalk(ast, [], fn node, acc -> {node, collect_node(node, acc)} end)
    Enum.reverse(evidence)
  end

  def kinds do
    [
      :manual_path_basename,
      :manual_path_extension,
      :manual_query_parsing,
      :manual_uri_path_split,
      :manual_uri_scheme_split
    ]
  end

  def collect_node({:|>, meta, [left, right]} = node, acc) do
    acc = collect_pipe_node(left, right, meta, acc)
    collect_direct(node, acc)
  end

  def collect_node(node, acc), do: collect_direct(node, acc)

  defp collect_pipe_node(left, right, meta, acc) do
    case {split_call(left), pipe_reader(right)} do
      {{:string_split, subject, "/", _split_meta}, {:last, _reader_meta}} ->
        maybe_evidence(
          acc,
          path_subject?(subject),
          :manual_path_basename,
          "manual path basename extraction; use Path.basename/1",
          "Path.basename/1",
          meta,
          :high
        )

      {{:string_split, subject, ".", _split_meta}, {:last, _reader_meta}} ->
        maybe_evidence(
          acc,
          path_subject?(subject),
          :manual_path_extension,
          "manual path extension extraction; use Path.extname/1",
          "Path.extname/1",
          meta,
          :high
        )

      {{:string_split, subject, "?", _split_meta}, {:first, _reader_meta}} ->
        maybe_evidence(
          acc,
          uri_subject?(subject),
          :manual_uri_path_split,
          "manual URL splitting; use URI.parse/1",
          "URI.parse/1",
          meta,
          :medium
        )

      _ ->
        acc
    end
  end

  defp collect_direct(node, acc) do
    case split_call(node) do
      {:string_split, subject, "&", meta} ->
        maybe_evidence(
          acc,
          uri_subject?(subject),
          :manual_query_parsing,
          "manual query-string splitting; use URI.decode_query/1",
          "URI.decode_query/1",
          meta,
          :medium
        )

      {:string_split, subject, "://", meta} ->
        maybe_evidence(
          acc,
          uri_subject?(subject),
          :manual_uri_scheme_split,
          "manual URL scheme splitting; use URI.parse/1",
          "URI.parse/1",
          meta,
          :medium
        )

      _ ->
        acc
    end
  end

  defp split_call(
         {:|>, _pipe_meta,
          [
            subject,
            {{:., meta, [{:__aliases__, _, [:String]}, :split]}, _call_meta, [delimiter | _]}
          ]}
       )
       when is_binary(delimiter),
       do: {:string_split, subject, delimiter, meta}

  defp split_call(
         {{:., meta, [{:__aliases__, _, [:String]}, :split]}, _call_meta,
          [subject, delimiter | _]}
       )
       when is_binary(delimiter),
       do: {:string_split, subject, delimiter, meta}

  defp split_call({:split, meta, [subject, delimiter | _]}) when is_binary(delimiter),
    do: {:string_split, subject, delimiter, meta}

  defp split_call(_), do: nil

  defp pipe_reader({{:., meta, [{:__aliases__, _, [:List]}, fun]}, _call_meta, []})
       when fun in [:last, :first],
       do: {fun, meta}

  defp pipe_reader({{:., meta, [{:__aliases__, _, [:Enum]}, :at]}, _call_meta, [index]})
       when index in [-1, 0],
       do: {if(index == -1, do: :last, else: :first), meta}

  defp pipe_reader({fun, meta, []}) when fun in [:hd], do: {:first, meta}
  defp pipe_reader(_), do: nil

  defp maybe_evidence(acc, false, _kind, _message, _replacement, _meta, _confidence), do: acc

  defp maybe_evidence(acc, true, kind, message, replacement, meta, confidence) do
    [
      %Evidence{
        kind: kind,
        message: message,
        replacement: replacement,
        meta: meta,
        confidence: confidence
      }
      | acc
    ]
  end

  defp path_subject?(subject), do: subject_name(subject) in @path_names
  defp uri_subject?(subject), do: subject_name(subject) in @uri_names

  defp subject_name({name, _meta, context}) when is_atom(name) and is_atom(context), do: name
  defp subject_name(_), do: nil
end
