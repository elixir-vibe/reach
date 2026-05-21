defmodule Reach.Source.Span do
  @moduledoc "Source span metadata used by lowered plugin AST and Reach IR nodes."

  @type t :: %__MODULE__{
          file: String.t() | nil,
          start_line: pos_integer() | nil,
          start_col: pos_integer() | nil,
          end_line: pos_integer() | nil,
          end_col: pos_integer() | nil
        }

  defstruct [:file, :start_line, :start_col, :end_line, :end_col]

  def from_meta(meta, file) when is_list(meta) do
    case meta[:line] do
      nil ->
        nil

      line ->
        %__MODULE__{
          file: file,
          start_line: line,
          start_col: meta[:column] || 1,
          end_line: nil,
          end_col: nil
        }
    end
  end

  def from_meta(_, _), do: nil

  def to_map(nil), do: nil

  def to_map(%__MODULE__{} = span) do
    %{
      file: span.file,
      start_line: span.start_line,
      start_col: span.start_col,
      end_line: span.end_line,
      end_col: span.end_col
    }
  end

  def to_map(%{} = span), do: span
end
