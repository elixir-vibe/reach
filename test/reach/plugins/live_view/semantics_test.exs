defmodule Reach.Plugins.LiveView.SemanticsTest do
  use ExUnit.Case, async: true

  alias Reach.Frontend.Elixir, as: ElixirFrontend
  alias Reach.IR
  alias Reach.Plugins.LiveView

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
