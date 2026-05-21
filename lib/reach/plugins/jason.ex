defmodule Reach.Plugins.Jason do
  @moduledoc "Plugin for Jason effect classification and JSON encoder smells."
  @behaviour Reach.Plugin

  alias Reach.IR.Node

  @impl true
  def smell_checks do
    [Reach.Plugins.Jason.Smells.HandRolledEncoder]
  end

  @impl true
  def classify_effect(%Node{type: :call, meta: %{module: Jason}}), do: :pure
  def classify_effect(_), do: nil

  @impl true
  def analyze(_all_nodes, _opts), do: []
end
