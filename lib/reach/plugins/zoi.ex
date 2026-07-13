defmodule Reach.Plugins.Zoi do
  @moduledoc "Plugin for Zoi schema declarations."
  @behaviour Reach.Plugin

  alias Reach.Plugins.SchemaFacts

  @impl true
  def analyze(_nodes, _opts), do: []

  @impl true
  def inference_hints, do: %{deps: [:zoi], source: ["Zoi."]}

  @impl true
  def macro_facts(ast, context) do
    SchemaFacts.zoi(ast, context[:file])
  end
end
