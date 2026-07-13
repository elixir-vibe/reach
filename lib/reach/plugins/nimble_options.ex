defmodule Reach.Plugins.NimbleOptions do
  @moduledoc "Plugin for NimbleOptions schema declarations."
  @behaviour Reach.Plugin

  alias Reach.Plugins.SchemaFacts

  @impl true
  def analyze(_nodes, _opts), do: []

  @impl true
  def inference_hints, do: %{deps: [:nimble_options], source: ["NimbleOptions."]}

  @impl true
  def macro_facts(ast, context) do
    SchemaFacts.nimble_options(ast, context[:file])
  end
end
