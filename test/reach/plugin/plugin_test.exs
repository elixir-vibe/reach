defmodule Reach.PluginsTest do
  use ExUnit.Case, async: true

  alias Reach.IR.Node
  alias Reach.Plugin
  alias Reach.Plugins
  alias Reach.Trace.Pattern
  alias Reach.Trace.Pattern.Preset

  defmodule TracePresetPlugin do
    @behaviour Reach.Plugin

    @impl true
    def analyze(_nodes, _opts), do: []

    @impl true
    def trace_preset("custom") do
      matcher = fn node -> node.type == :literal end

      %Preset{
        name: "custom",
        from: "custom source",
        to: "custom sink",
        routes: [%{source: matcher, sink: matcher}]
      }
    end

    def trace_preset(_pattern), do: nil
  end

  describe "plugin trace patterns" do
    test "Phoenix owns conn params pattern" do
      matcher = Plugin.trace_pattern([Plugins.Phoenix], "conn.params")

      assert matcher.(%Node{type: :var, id: 1, meta: %{name: :params}})

      refute Pattern.compile("conn.params", []).(%Node{
               type: :var,
               id: 2,
               meta: %{name: :params}
             })
    end

    test "plugins can own named trace presets" do
      assert {:ok, %Preset{name: "custom"}} = Pattern.preset("custom", [TracePresetPlugin])
      assert :error = Pattern.preset("custom", [])
    end

    test "Ecto owns repo sink pattern" do
      matcher = Plugin.trace_pattern([Plugins.Ecto], "Repo")

      assert matcher.(%Node{
               type: :call,
               id: 1,
               meta: %{kind: :remote, module: MyApp.Repo, function: :insert, arity: 1}
             })

      refute Pattern.compile("Repo", []).(%Node{
               type: :call,
               id: 2,
               meta: %{kind: :remote, module: MyApp.Repo, function: :insert, arity: 1}
             })
    end
  end

  describe "Ecto plugin" do
    test "tracks cast params to Repo.insert within same function" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyApp do
            def create(params) do
              %User{}
              |> cast(params, [:name, :email])
              |> Repo.insert()
            end

            def unrelated do
              Repo.insert(%Other{})
            end
          end
          """,
          plugins: [Reach.Plugins.Ecto]
        )

      edges = Reach.edges(graph)
      flow_edges = Enum.filter(edges, &match?({:ecto_changeset_flow, _}, &1.label))

      assert length(flow_edges) == 1

      [edge] = flow_edges
      cast_node = Reach.nodes(graph) |> Enum.find(&(&1.meta[:function] == :cast))
      insert_node = Reach.nodes(graph) |> Enum.find(&(&1.meta[:function] == :insert))
      assert edge.v1 == cast_node.id
      assert edge.v2 == insert_node.id
    end

    test "tracks raw SQL query params" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyApp do
            def unsafe(input) do
              Repo.query("SELECT * FROM users WHERE id = " <> input)
            end
          end
          """,
          plugins: [Reach.Plugins.Ecto]
        )

      edges = Reach.edges(graph)
      raw_edges = Enum.filter(edges, &(&1.label == :ecto_raw_query))
      assert raw_edges != []

      input_var =
        Reach.nodes(graph)
        |> Enum.find(&(&1.meta[:name] == :input and &1.meta[:binding_role] != :definition))

      assert Enum.any?(raw_edges, &(&1.v1 == input_var.id))
    end

    test "cast_params edge connects param var to cast call" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyApp do
            def create(params) do
              cast(%User{}, params, [:name])
            end
          end
          """,
          plugins: [Reach.Plugins.Ecto]
        )

      edges = Reach.edges(graph)
      cast_edges = Enum.filter(edges, &(&1.label == :ecto_cast_params))
      assert length(cast_edges) == 1

      [edge] = cast_edges

      params_var =
        Reach.nodes(graph)
        |> Enum.find(&(&1.meta[:name] == :params and &1.meta[:binding_role] != :definition))

      cast_call = Reach.nodes(graph) |> Enum.find(&(&1.meta[:function] == :cast))
      assert edge.v1 == params_var.id
      assert edge.v2 == cast_call.id
    end
  end

  describe "Phoenix plugin" do
    test "marks param pattern vars as taint sources" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyController do
            def create(conn, params) do
              do_thing(params)
            end
          end
          """,
          plugins: [Reach.Plugins.Phoenix]
        )

      edges = Reach.edges(graph)
      param_edges = Enum.filter(edges, &(&1.label == :phoenix_params))
      assert length(param_edges) == 1

      [edge] = param_edges
      assert edge.v1 != edge.v2
    end

    test "action_fallback scoped to per-function error tuples" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyController do
            action_fallback(ErrorController)

            def create(conn, params) do
              case do_thing(params) do
                {:ok, result} -> json(conn, result)
                {:error, changeset} -> {:error, changeset}
              end
            end

            def show(conn, %{"id" => id}) do
              {:ok, fetch(id)}
            end
          end
          """,
          plugins: [Reach.Plugins.Phoenix]
        )

      edges = Reach.edges(graph)
      fb_edges = Enum.filter(edges, &(&1.label == :phoenix_action_fallback))

      fb_node = Reach.nodes(graph) |> Enum.find(&(&1.meta[:function] == :action_fallback))
      assert Enum.all?(fb_edges, &(&1.v2 == fb_node.id))

      error_nodes =
        Reach.nodes(graph)
        |> Enum.filter(fn n ->
          n.type == :tuple and match?([%{type: :literal, meta: %{value: :error}} | _], n.children)
        end)

      fb_sources = MapSet.new(fb_edges, & &1.v1)

      for err <- error_nodes do
        assert err.id in fb_sources
      end
    end

    test "detects socket assign flow" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyLive do
            def mount(params, session, socket) do
              assign(socket, :user, session)
            end
          end
          """,
          plugins: [Reach.Plugins.Phoenix]
        )

      edges = Reach.edges(graph)
      assign_edges = Enum.filter(edges, &(&1.label == :phoenix_assign))
      assert assign_edges != []

      assign_call = Reach.nodes(graph) |> Enum.find(&(&1.meta[:function] == :assign))
      assert Enum.all?(assign_edges, &(&1.v2 == assign_call.id))
    end
  end

  describe "Oban plugin" do
    test "connects perform param to its uses, not to every call" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyWorker do
            def perform(job) do
              process(job)
              log_done()
            end
          end
          """,
          plugins: [Reach.Plugins.Oban]
        )

      edges = Reach.edges(graph)
      oban_edges = Enum.filter(edges, &(&1.label == :oban_job_args))

      job_uses =
        Reach.nodes(graph)
        |> Enum.filter(fn n ->
          n.type == :var and n.meta[:name] == :job and n.meta[:binding_role] != :definition
        end)

      assert length(oban_edges) == length(job_uses)

      for edge <- oban_edges do
        assert Enum.any?(job_uses, &(&1.id == edge.v2))
      end
    end
  end

  describe "GenStage plugin" do
    test "connects handle_demand return to handle_events param" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyStage do
            def handle_demand(demand, state) do
              {:noreply, fetch(demand), state}
            end

            def handle_events(events, _from, state) do
              process(events)
              {:noreply, [], state}
            end
          end
          """,
          plugins: [Reach.Plugins.GenStage]
        )

      edges = Reach.edges(graph)
      stage_edges = Enum.filter(edges, &(&1.label == :gen_stage_pipeline))
      assert stage_edges != []

      for edge <- stage_edges do
        assert edge.v1 != edge.v2
      end
    end

    test "connects handle_message return to handle_batch param" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyBroadway do
            def handle_message(_, message, _) do
              message
            end

            def handle_batch(:default, messages, _, _) do
              send_all(messages)
            end
          end
          """,
          plugins: [Reach.Plugins.GenStage]
        )

      edges = Reach.edges(graph)
      broadway_edges = Enum.filter(edges, &(&1.label == :broadway_pipeline))
      assert broadway_edges != []

      for edge <- broadway_edges do
        assert edge.v1 != edge.v2
      end
    end
  end

  describe "plugin infrastructure" do
    test "detect returns list" do
      plugins = Reach.Plugin.detect()
      assert is_list(plugins)
    end

    test "plugins: [] disables all plugins" do
      assert Reach.Plugin.resolve(plugins: []) == []
    end

    test "plugins: [mod] overrides auto-detection" do
      assert Reach.Plugin.resolve(plugins: [Reach.Plugins.Ecto]) == [Reach.Plugins.Ecto]
    end

    test "no plugins option uses auto-detection" do
      plugins = Reach.Plugin.resolve([])
      assert is_list(plugins)
    end
  end
end
