defmodule Reach.Plugins.Poison do
  @moduledoc "Plugin for Poison effect classification."
  @behaviour Reach.Plugin

  alias Reach.IR.Node

  @impl true
  def classify_effect(%Node{type: :call, meta: %{module: Poison}}), do: :pure

  def classify_effect(_), do: nil

  @impl true
  def analyze(_all_nodes, _opts), do: []
end
