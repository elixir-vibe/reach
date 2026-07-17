defmodule Reach.Plugins.Jason do
  @moduledoc "Plugin for Jason effect classification and JSON encoder smells."
  @behaviour Reach.Plugin

  alias Reach.Evidence.{AST, MapContract}
  alias Reach.IR.Node

  @impl true
  def inference_hints do
    %{deps: [:jason], source: ["Jason."]}
  end

  @impl true
  def smell_checks do
    [Reach.Plugins.Jason.Smells.HandRolledEncoder]
  end

  @impl true
  def evidence_providers do
    [Reach.Plugins.Jason.Evidence.HandRolledEncoder]
  end

  @impl true
  def classify_effect(%Node{type: :call, meta: %{module: Jason}}), do: :pure
  def classify_effect(_), do: nil

  @impl true
  def refine_evidence(%MapContract.Contract{escapes: escapes}, _context) do
    if Enum.any?(escapes || [], &jason_encode_escape?/1) do
      %{role: :external_payload}
    else
      :unchanged
    end
  end

  def refine_evidence(_evidence, _context), do: :unchanged

  @impl true
  def external_data_source({:|>, _meta, [_input, decoder]}), do: decode_source(decoder, 1)
  def external_data_source(ast), do: decode_source(ast, 0)

  @impl true
  def analyze(_all_nodes, _opts), do: []

  defp decode_source(ast, piped_arity) do
    with {:ok, %{module: Jason, function: function, arity: arity}} <- AST.call_descriptor(ast),
         true <- function in [:decode, :decode!],
         effective_arity = arity + piped_arity,
         true <- effective_arity in [1, 2] do
      "Jason.#{function}/#{effective_arity}"
    else
      _other -> nil
    end
  end

  defp jason_encode_escape?(%{module: Jason, function: function, arity: arity}) do
    function in [:encode, :encode!] and arity in [1, 2]
  end

  defp jason_encode_escape?(_escape), do: false
end
