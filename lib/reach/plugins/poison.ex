defmodule Reach.Plugins.Poison do
  @moduledoc "Plugin for Poison effect classification."
  @behaviour Reach.Plugin

  alias Reach.Evidence.AST
  alias Reach.IR.Node

  @impl true
  def inference_hints do
    %{deps: [:poison], source: ["Poison."]}
  end

  @impl true
  def classify_effect(%Node{type: :call, meta: %{module: Poison}}), do: :pure

  def classify_effect(_), do: nil

  @impl true
  def external_data_source({:|>, _meta, [_input, decoder]}), do: decode_source(decoder, 1)
  def external_data_source(ast), do: decode_source(ast, 0)

  @impl true
  def analyze(_all_nodes, _opts), do: []

  defp decode_source(ast, piped_arity) do
    with {:ok, %{module: Poison, function: function, arity: arity}} <- AST.call_descriptor(ast),
         true <- function in [:decode, :decode!],
         effective_arity = arity + piped_arity,
         true <- effective_arity in [1, 2] do
      "Poison.#{function}/#{effective_arity}"
    else
      _other -> nil
    end
  end
end
