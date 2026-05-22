defmodule Reach.Plugins.LiveView.HEExLowererTest do
  use ExUnit.Case, async: true

  alias Reach.Frontend.Elixir, as: ElixirFrontend
  alias Reach.IR.Counter
  alias Reach.Plugins.LiveView.HEEx.Lowerer
  alias Reach.Plugins.LiveView.HEEx.Node
  alias Reach.Source.Span

  test "lowers special :for and :if attributes to separate control nodes with HEEx origins" do
    span = %Span{file: "demo.heex", start_line: 2, start_col: 1}

    tree = %Node.Template{
      children: [
        %Node.Tag{
          type: :tag,
          name: "li",
          open_span: span,
          span: span,
          attrs: [],
          special: [
            %Node.SpecialAttr{
              name: :for,
              code: "item <- @items",
              ast:
                {:<-, [line: 2, column: 6],
                 [
                   {:item, [line: 2, column: 6], nil},
                   {:@, [line: 2, column: 14], [{:items, [line: 2, column: 15], nil}]}
                 ]},
              span: span
            },
            %Node.SpecialAttr{
              name: :if,
              code: "item.visible?",
              ast:
                {{:., [line: 2, column: 28], [{:item, [line: 2, column: 28], nil}, :visible?]},
                 [line: 2, column: 32], []},
              span: span
            }
          ],
          children: [
            %Node.Expr{
              code: "item.name",
              ast:
                {{:., [line: 2, column: 45], [{:item, [line: 2, column: 45], nil}, :name]},
                 [line: 2, column: 49], []},
              span: span
            }
          ]
        }
      ],
      span: span
    }

    ast = Lowerer.to_ast(tree)
    nodes = ElixirFrontend.translate_ast(ast, Counter.new(), "demo.heex") |> flatten()

    assert Enum.any?(nodes, &(&1.type == :comprehension and &1.source_span.start_line == 2))
    assert Enum.any?(nodes, &(&1.type == :generator and &1.meta.origin.kind == :for))
    assert Enum.any?(nodes, &(&1.type == :case and &1.meta.origin.kind == :if))
  end

  test "lowers phx event attributes to synthetic event calls" do
    span = %Span{file: "demo.heex", start_line: 1, start_col: 1}

    tree = %Node.Template{
      children: [
        %Node.Tag{
          type: :tag,
          name: "button",
          open_span: span,
          span: span,
          attrs: [%Node.Attr{name: "phx-click", value: {:string, "save"}, span: span}],
          special: [],
          children: [%Node.Text{text: "Save", span: span}]
        }
      ],
      span: span
    }

    ast = Lowerer.to_ast(tree)
    nodes = ElixirFrontend.translate_ast(ast, Counter.new(), "demo.heex") |> flatten()

    assert Enum.any?(nodes, &(&1.type == :call and &1.meta[:function] == :__live_event__))
  end

  test "lowers local components to component calls instead of LiveView runtime helpers" do
    span = %Span{file: "demo.heex", start_line: 1, start_col: 1}

    tree = %Node.Template{
      children: [
        %Node.Tag{
          type: :local_component,
          name: "card",
          open_span: span,
          span: span,
          attrs: [
            %Node.Attr{
              name: "title",
              value:
                {:expr, "@title",
                 {:@, [line: 1, column: 15], [{:title, [line: 1, column: 16], nil}]}},
              span: span
            }
          ],
          special: [],
          children: []
        }
      ],
      span: span
    }

    ast = Lowerer.to_ast(tree)
    nodes = ElixirFrontend.translate_ast(ast, Counter.new(), "demo.heex") |> flatten()

    assert Enum.any?(nodes, &(&1.type == :call and &1.meta[:function] == :card))

    refute Enum.any?(
             nodes,
             &(&1.type == :call and &1.meta[:module] == Phoenix.LiveView.TagEngine)
           )
  end

  defp flatten(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &flatten/1)
  defp flatten(%{children: children} = node), do: [node | flatten(children)]
end
