defmodule Reach.Plugins.LiveView do
  @moduledoc "Plugin for LiveView and HEEx template semantics."
  @behaviour Reach.Plugin

  alias Reach.IR.Node
  alias Reach.Plugins.LiveView.HEEx

  @pure_local [
    :assign,
    :assign_new,
    :push_event,
    :push_patch,
    :push_navigate,
    :put_flash,
    :redirect,
    :live_render,
    :live_component,
    :on_mount,
    :sigil_H,
    :sigil_p
  ]

  @pure_remote_modules [Phoenix.Component, Phoenix.LiveView]

  @impl true
  def analyze(_all_nodes, _opts), do: []

  @impl true
  def source_extensions, do: [".heex"]

  @impl true
  def source_language(".heex"), do: :heex
  def source_language(_), do: nil

  @impl true
  def parse_file(path, opts), do: HEEx.parse_file(path, opts)

  @impl true
  def lower_elixir_ast({:sigil_H, meta, [{:<<>>, _, [source]}, modifiers]}, opts)
      when is_binary(source) and modifiers in [[], ~c"noformat"] do
    HEEx.lower_sigil(source, meta, opts)
  end

  def lower_elixir_ast(_ast, _opts), do: :ignore

  @impl true
  def classify_effect(%Node{type: :call, meta: %{kind: :local, function: fun}})
      when fun in @pure_local,
      do: :pure

  def classify_effect(%Node{type: :call, meta: %{kind: :remote, module: mod}})
      when mod in @pure_remote_modules,
      do: :pure

  def classify_effect(_), do: nil

  @impl true
  def behaviour_label(callbacks) do
    if :mount in callbacks and :render in callbacks, do: "LiveView"
  end

  @impl true
  def ignore_call_edge?(%Graph.Edge{v2: {Phoenix.LiveView.TagEngine, fun, _arity}})
      when fun in [:component, :inner_block],
      do: true

  def ignore_call_edge?(_edge), do: false
end
