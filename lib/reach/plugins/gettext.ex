defmodule Reach.Plugins.Gettext do
  @moduledoc "Plugin for Gettext backend and locale management semantics."

  @behaviour Reach.Plugin

  alias Reach.IR.Node
  alias Reach.MacroFact

  @impl true
  def inference_hints do
    %{deps: [:gettext], source: ["Gettext", "Gettext.Macros"]}
  end

  @impl true
  def analyze(_all_nodes, _opts), do: []

  @impl true
  def classify_effect(%Node{
        type: :call,
        meta: %{kind: :remote, module: Gettext, function: fun, arity: arity}
      })
      when {fun, arity} in [{:put_locale, 1}, {:put_locale, 2}, {:put_locale!, 2}] do
    :write
  end

  def classify_effect(_), do: nil

  @impl true
  def refine_macro_fact(%MacroFact{name: :use, target: Gettext} = fact, _context) do
    %{fact | framework: :gettext, kind: :gettext_use, confidence: :high}
  end

  def refine_macro_fact(_fact, _context), do: :unchanged
end
