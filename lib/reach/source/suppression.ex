defmodule Reach.Source.Suppression do
  @moduledoc "Parses source suppression directives and their justifications."

  alias Reach.Project.Query

  @next_line_prefix "# reach:disable-next-line"
  @this_file_prefix "# reach:disable-for-this-file"
  @disable_prefix "# reach:disable"

  defmodule Directive do
    @moduledoc "A parsed source-suppression directive and its effective scope."
    @derive JSON.Encoder
    @enforce_keys [:scope, :tokens, :file, :line]
    defstruct [:scope, :tokens, :reason, :file, :line, :target_line]

    @type t :: %__MODULE__{
            scope: :next_line | :file,
            tokens: [String.t()],
            reason: String.t() | nil,
            file: Path.t(),
            line: pos_integer(),
            target_line: pos_integer() | nil
          }
  end

  @type summary :: %{total: non_neg_integer(), reasonless: non_neg_integer()}

  @spec parse_file(Path.t()) :: [Directive.t()]
  def parse_file(file) do
    case File.read(file) do
      {:ok, source} -> parse_source(source, file)
      {:error, _reason} -> []
    end
  end

  @spec parse_source(String.t(), Path.t()) :: [Directive.t()]
  def parse_source(source, file) do
    case Code.string_to_quoted_with_comments(source, columns: true) do
      {:ok, _quoted, comments} ->
        Enum.flat_map(comments, fn %{text: text, line: line} ->
          parse_comment(text, file, line)
        end)

      {:error, _reason} ->
        []
    end
  end

  @spec project_summary(Reach.Project.t(), String.t() | nil) :: summary()
  def project_summary(project, path \\ nil) do
    directives =
      project.nodes
      |> Enum.flat_map(fn
        {_id, %{type: :module_def, source_span: %{file: file}}} when is_binary(file) -> [file]
        _entry -> []
      end)
      |> Enum.uniq()
      |> Enum.filter(&Query.file_matches?(&1, path))
      |> Enum.flat_map(&parse_file/1)

    %{total: length(directives), reasonless: Enum.count(directives, &is_nil(&1.reason))}
  end

  defp parse_comment(comment, file, number) do
    trimmed = String.trim_leading(comment)

    cond do
      String.starts_with?(trimmed, @this_file_prefix) ->
        directive(:file, trimmed, @this_file_prefix, file, number, nil)

      String.starts_with?(trimmed, @next_line_prefix) ->
        directive(:next_line, trimmed, @next_line_prefix, file, number, number + 1)

      String.starts_with?(trimmed, @disable_prefix) ->
        directive(:next_line, trimmed, @disable_prefix, file, number, number + 1)

      true ->
        []
    end
  end

  defp directive(scope, line, prefix, file, number, target_line) do
    {tokens, reason} =
      line
      |> String.trim()
      |> String.replace_prefix(prefix, "")
      |> split_reason()

    if tokens == [] do
      []
    else
      [
        %Directive{
          scope: scope,
          tokens: tokens,
          reason: reason,
          file: file,
          line: number,
          target_line: target_line
        }
      ]
    end
  end

  defp split_reason(rest) do
    case String.split(rest, ~r/\s+--\s*/, parts: 2) do
      [tokens] -> {tokens(tokens), nil}
      [tokens, reason] -> {tokens(tokens), nonempty_reason(reason)}
    end
  end

  defp tokens(value) do
    value
    |> String.split([",", " ", "\t"], trim: true)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp nonempty_reason(reason) do
    case String.trim(reason) do
      "" -> nil
      reason -> reason
    end
  end
end
