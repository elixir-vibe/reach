defmodule Reach.Plugins.Jason do
  @moduledoc "Plugin for Jason effect classification and JSON encoder smells."
  @behaviour Reach.Plugin

  alias Reach.Evidence.MapContract
  alias Reach.IR.Node

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
  def analyze(_all_nodes, _opts), do: []

  defp jason_encode_escape?(%{module: Jason, function: function, arity: arity}) do
    function in [:encode, :encode!] and arity in [1, 2]
  end

  defp jason_encode_escape?(_escape), do: false
end
