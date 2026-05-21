defmodule Reach.Source do
  @moduledoc "Helpers for attaching source-origin metadata to lowered AST."

  alias Reach.Source.{Origin, Span}

  @metadata_key :reach

  def metadata_key, do: @metadata_key

  def origin(meta) when is_list(meta), do: Keyword.get(meta, @metadata_key)
  def origin(_), do: nil

  def put_origin({form, meta, args}, %Origin{} = origin) when is_list(meta) and is_list(args) do
    {form, Keyword.put(meta, @metadata_key, origin), args}
  end

  def put_origin(ast, _origin), do: ast

  def span_from_origin(%Origin{span: span}), do: Span.to_map(span)
  def span_from_origin(_), do: nil
end
