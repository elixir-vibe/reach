defmodule Reach.Map.Summary do
  @moduledoc "Struct for project-level summary statistics."
  @derive JSON.Encoder
  defstruct [
    :modules,
    :functions,
    :call_graph_vertices,
    :call_graph_edges,
    :graph_nodes,
    :graph_edges,
    :effects,
    suppressions: %{total: 0, reasonless: 0}
  ]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
