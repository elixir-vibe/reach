defmodule Reach.Plugins.LiveViewTest do
  use ExUnit.Case, async: true

  alias Reach.Plugins.LiveView

  test "owns HEEx sources" do
    assert LiveView.source_extensions() == [".heex"]
    assert LiveView.source_language(".heex") == :heex
  end

  test "reports unavailable LiveView when lowering without phoenix_live_view loaded" do
    ast = {:sigil_H, [line: 1, column: 1], [{:<<>>, [line: 1], ["<p>Hello</p>"]}, []]}

    unless Code.ensure_loaded?(Phoenix.LiveView.TagEngine) do
      assert LiveView.lower_elixir_ast(ast, file: "demo.ex") == {:error, :live_view_not_available}
    end
  end

  test "hides LiveView rendering helper calls from call graph presentation" do
    assert LiveView.ignore_call_edge?(%Graph.Edge{
             v1: {Demo, :render, 1},
             v2: {Phoenix.LiveView.TagEngine, :component, 3},
             label: nil
           })

    assert LiveView.ignore_call_edge?(%Graph.Edge{
             v1: {Demo, :render, 1},
             v2: {Phoenix.LiveView.TagEngine, :inner_block, 2},
             label: nil
           })

    refute LiveView.ignore_call_edge?(%Graph.Edge{
             v1: {Demo, :render, 1},
             v2: {Demo, :component, 1},
             label: nil
           })
  end
end
