defmodule Reach.Plugins.LiveView.SemanticsTest do
  use ExUnit.Case, async: true

  alias Reach.Frontend.Elixir, as: ElixirFrontend
  alias Reach.IR
  alias Reach.IR.Counter
  alias Reach.Plugins.LiveView
  alias Reach.Plugins.LiveView.HEEx.Lowerer
  alias Reach.Plugins.LiveView.HEEx.Node
  alias Reach.Source.Span

  test "connects template events to handle_event clauses" do
    nodes =
      parse!("""
      defmodule Demo do
        def render(assigns), do: __live_event__("save")
        def handle_event("save", _params, socket), do: {:noreply, socket}
      end
      """)

    assert Enum.any?(
             LiveView.analyze(IR.all_nodes(nodes), []),
             &match?({_, _, {:live_event, "save"}}, &1)
           )
  end

  test "connects assign writes to template assign reads" do
    nodes =
      parse!("""
      defmodule Demo do
        def mount(socket) do
          assign(socket, :user, load_user())
        end

        def render(assigns), do: @user
      end
      """)

    assert Enum.any?(
             LiveView.analyze(IR.all_nodes(nodes), []),
             &match?({_, _, {:live_assign, :user}}, &1)
           )
  end

  test "does not connect generated LiveView runtime component helper attrs" do
    nodes =
      parse!("""
      defmodule Demo do
        def render(assigns) do
          Phoenix.LiveView.TagEngine.component(&card/1, %{user: @user}, {__MODULE__, :render, __ENV__.file, 1})
        end
      end
      """)

    refute Enum.any?(
             LiveView.analyze(IR.all_nodes(nodes), []),
             &match?({_, _, {:live_component_attr, :user}}, &1)
           )
  end

  test "connects component attr values to parser-lowered component calls" do
    nodes =
      parse!("""
      defmodule Demo do
        def render(assigns), do: card(%{user: @user})
      end
      """)

    component_call =
      nodes |> IR.all_nodes() |> Enum.find(&(&1.type == :call and &1.meta[:function] == :card))

    origin = %Reach.Source.Origin{
      language: :heex,
      kind: :component,
      label: "<.card>",
      plugin: LiveView,
      generated?: true
    }

    component_call = %{component_call | meta: Map.put(component_call.meta, :origin, origin)}

    all_nodes = replace_node(nodes, component_call.id, component_call) |> IR.all_nodes()

    assert Enum.any?(
             LiveView.analyze(all_nodes, []),
             &match?({_, _, {:live_component_attr, :user}}, &1)
           )
  end

  test "connects stream writes to @streams reads" do
    nodes =
      parse!("""
      defmodule Demo do
        def mount(socket), do: stream(socket, :posts, [])
        def render(assigns), do: @streams.posts
      end
      """)

    assert Enum.any?(
             LiveView.analyze(IR.all_nodes(nodes), []),
             &match?({_, _, {:live_stream, :posts}}, &1)
           )
  end

  test "events and components inside :if branches get heex_output edges" do
    span = %Span{file: "demo.heex", start_line: 1, start_col: 1}
    output_span = %Span{file: "demo.heex", start_line: 2, start_col: 1}

    tree = %Node.Template{
      children: [
        %Node.Tag{
          type: :tag,
          name: "div",
          open_span: span,
          span: span,
          attrs: [],
          special: [],
          children: [
            %Node.Tag{
              type: :tag,
              name: "button",
              open_span: span,
              span: span,
              attrs: [%Node.Attr{name: "phx-click", value: {:string, "toggle"}, span: span}],
              special: [
                %Node.SpecialAttr{
                  name: :if,
                  code: "@show",
                  ast: {:@, [line: 1], [{:show, [line: 1], nil}]},
                  span: span
                }
              ],
              children: [%Node.Text{text: "T", span: span}]
            },
            %Node.Tag{
              type: :local_component,
              name: "icon",
              open_span: span,
              span: span,
              attrs: [%Node.Attr{name: "name", value: {:string, "hero-check"}, span: span}],
              special: [
                %Node.SpecialAttr{
                  name: :if,
                  code: "@show",
                  ast: {:@, [line: 1], [{:show, [line: 1], nil}]},
                  span: span
                }
              ],
              children: []
            },
            %Node.Text{text: "output", span: output_span}
          ]
        }
      ],
      span: span
    }

    template_ast = Lowerer.to_ast(tree)

    wrapper =
      quote do
        defmodule EventComponent do
          def render(assigns), do: unquote(template_ast)
        end
      end

    plugins = [LiveView]
    nodes = ElixirFrontend.translate_ast(wrapper, Counter.new(), "demo.heex", plugins: plugins)
    graph = Reach.SystemDependence.build(nodes, plugins: plugins)
    all = IR.all_nodes(nodes)

    event = Enum.find(all, &(&1.type == :call and &1.meta[:function] == :__live_event__))
    icon = Enum.find(all, &(&1.type == :call and &1.meta[:function] == :icon))
    event_edges = Enum.filter(Reach.edges(graph), &(&1.v1 == event.id))
    icon_edges = Enum.filter(Reach.edges(graph), &(&1.v1 == icon.id))

    assert Enum.any?(event_edges, &match?({:heex_output, _}, &1.label))
    assert Enum.any?(icon_edges, &match?({:heex_output, _}, &1.label))
    refute event in Reach.dead_code(graph)
    refute icon in Reach.dead_code(graph)
  end

  defp parse!(source) do
    {:ok, nodes} = ElixirFrontend.parse(source, file: "demo.ex", plugins: [])
    nodes
  end

  defp replace_node(nodes, id, replacement) when is_list(nodes),
    do: Enum.map(nodes, &replace_node(&1, id, replacement))

  defp replace_node(%{id: id} = _node, id, replacement), do: replacement

  defp replace_node(%{children: children} = node, id, replacement),
    do: %{node | children: replace_node(children, id, replacement)}
end
