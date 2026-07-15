defmodule Reach.Plugins.Nx do
  @moduledoc "Plugin for Nx.Defn numerical-definition DSL semantics."
  @behaviour Reach.Plugin

  alias Reach.AST

  @defn_macros [:defn, :defnp]

  @impl true
  def analyze(_nodes, _opts), do: []

  @impl true
  def inference_hints, do: %{deps: [:nx], source: ["Nx", "Nx.Defn"]}

  @impl true
  def reinterpreted_ast?(ast) do
    case AST.call(ast) do
      {nil, name, [_head, body]} when name in @defn_macros -> keyword_body?(body)
      {Nx.Defn, name, [_head, body]} when name in @defn_macros -> keyword_body?(body)
      _other -> false
    end
  end

  defp keyword_body?(body), do: AST.keyword?(body, :do)
end
