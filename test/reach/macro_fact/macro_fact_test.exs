defmodule Reach.MacroFactTest do
  use ExUnit.Case, async: true

  alias Reach.MacroFact

  test "collects module-level DSL declarations and nested declaration blocks" do
    source = ~S'''
    defmodule MyAppWeb.Router do
      use Phoenix.Router

      pipeline :browser do
        plug :accepts, ["html"]
      end

      scope "/", MyAppWeb do
        pipe_through :browser
        get "/health", HealthController, :show
      end
    end
    '''

    assert {:ok, facts} = MacroFact.collect_source(source, file: "router.ex")

    assert Enum.map(facts, & &1.name) == [:use, :pipeline, :plug, :scope, :pipe_through, :get]

    assert %MacroFact{
             owner_module: MyAppWeb.Router,
             target: Phoenix.Router,
             call_module: Phoenix.Router,
             source: %{file: "router.ex", line: 2},
             generated?: false
           } = Enum.at(facts, 0)

    assert %MacroFact{name: :plug, nesting: [:pipeline]} = Enum.at(facts, 2)

    assert %MacroFact{name: :get, arity: 3, nesting: [:scope], target: {nil, :get, 3}} =
             Enum.at(facts, 5)
  end

  test "lets plugins refine Phoenix declaration facts" do
    source = ~S'''
    defmodule MyAppWeb.PageComponent do
      use Phoenix.Component

      attr :title, :string
      slot :inner_block
    end
    '''

    assert {:ok, facts} = MacroFact.collect_source(source, plugins: [Reach.Plugins.Phoenix])

    assert [
             %MacroFact{
               kind: :phoenix_component_use,
               framework: :phoenix,
               data: %{explained_callbacks: [{:update, 2}, {:render, 1}]},
               confidence: :high
             },
             %MacroFact{kind: :phoenix_component_attr, framework: :phoenix, confidence: :high},
             %MacroFact{kind: :phoenix_component_slot, framework: :phoenix, confidence: :high}
           ] = facts
  end

  test "enriches Phoenix route targets" do
    source = ~S'''
    defmodule MyAppWeb.Router do
      use Phoenix.Router

      get "/health", HealthController, :show
      live "/dashboard", DashboardLive
    end
    '''

    assert {:ok, facts} = MacroFact.collect_source(source, plugins: [Reach.Plugins.Phoenix])

    assert %MacroFact{
             kind: :phoenix_route,
             target: %{
               route: :get,
               action: %{module: "MyAppWeb.HealthController", function: "show", arity: 2}
             },
             data: %{method: :get, args: ["\"/health\"", "HealthController", ":show"]}
           } = Enum.at(facts, 1)

    assert %MacroFact{
             kind: :phoenix_route,
             target: %{live_view: "MyAppWeb.DashboardLive"},
             data: %{method: :live}
           } = Enum.at(facts, 2)
  end

  test "Phoenix route target enrichment does not create module atoms" do
    source = ~S'''
    defmodule AtomSafeWeb.Router do
      use Phoenix.Router

      get "/health", DefinitelyNotCreatedController, :show
    end
    '''

    module_name = "Elixir.AtomSafeWeb.DefinitelyNotCreatedController"

    assert_raise ArgumentError, fn -> String.to_existing_atom(module_name) end
    assert {:ok, facts} = MacroFact.collect_source(source, plugins: [Reach.Plugins.Phoenix])

    assert %MacroFact{
             kind: :phoenix_route,
             target: %{action: %{module: "AtomSafeWeb.DefinitelyNotCreatedController"}}
           } = Enum.at(facts, 1)

    assert_raise ArgumentError, fn -> String.to_existing_atom(module_name) end
  end

  test "collects Ash-style declarations without descending into function bodies" do
    source = ~S'''
    defmodule MyApp.Blog.Post do
      use Ash.Resource, domain: MyApp.Blog

      attributes do
        uuid_primary_key :id
        attribute :title, :string
      end

      actions do
        defaults [:read]

        create :publish do
          accept [:title]
        end
      end

      def helper do
        ordinary_call()
      end
    end
    '''

    assert {:ok, facts} = MacroFact.collect_source(source)

    names = Enum.map(facts, & &1.name)

    assert names == [
             :use,
             :attributes,
             :uuid_primary_key,
             :attribute,
             :actions,
             :defaults,
             :create,
             :accept
           ]

    refute :ordinary_call in names
    assert %MacroFact{name: :accept, nesting: [:actions, :create]} = List.last(facts)
  end

  test "lets plugins refine Ash declaration facts" do
    source = ~S'''
    defmodule MyApp.Blog.Post do
      use Ash.Resource

      attributes do
        uuid_primary_key :id
        attribute :title, :string
      end

      actions do
        create :publish do
          accept [:title]
        end
      end
    end
    '''

    assert {:ok, facts} = MacroFact.collect_source(source, plugins: [Reach.Plugins.Ash])

    assert Enum.map(facts, & &1.kind) == [
             :ash_resource_use,
             :ash_resource_dsl,
             :ash_attribute,
             :ash_attribute,
             :ash_actions,
             :ash_action,
             :ash_resource_dsl
           ]
  end

  test "lets plugins refine Ecto declaration facts" do
    source = ~S'''
    defmodule MyApp.User do
      use Ecto.Schema

      schema "users" do
        field :email, :string
      end
    end
    '''

    assert {:ok, facts} = MacroFact.collect_source(source, plugins: [Reach.Plugins.Ecto])

    assert [
             %MacroFact{kind: :ecto_schema_use, framework: :ecto},
             %MacroFact{kind: :ecto_schema, framework: :ecto},
             %MacroFact{kind: :ecto_schema_field, framework: :ecto}
           ] = facts
  end

  test "filters facts with query helpers" do
    facts = [
      %MacroFact{
        kind: :phoenix_route,
        framework: :phoenix,
        owner_module: MyApp.Router,
        source: %{file: "router.ex", line: 10}
      },
      %MacroFact{
        kind: :ecto_schema,
        framework: :ecto,
        owner_module: MyApp.User,
        source: %{file: "user.ex", line: 3}
      }
    ]

    assert [%MacroFact{kind: :phoenix_route}] = MacroFact.by_kind(facts, :phoenix_route)
    assert [%MacroFact{framework: :ecto}] = MacroFact.by_framework(facts, :ecto)
    assert [%MacroFact{owner_module: MyApp.Router}] = MacroFact.by_owner(facts, MyApp.Router)

    assert [%MacroFact{source: %{line: 10}}] =
             MacroFact.at_source(facts, %{file: "router.ex", line: 10})
  end

  test "resolves local use macro aliases in project facts" do
    path = Path.join(System.tmp_dir!(), "reach-macro-fact-alias-#{System.unique_integer()}.ex")

    File.write!(path, ~S'''
    defmodule MyAppWeb do
      def live_view do
        quote do
          use Phoenix.LiveView
        end
      end
    end

    defmodule MyAppWeb.PageLive do
      use MyAppWeb, :live_view
    end
    ''')

    on_exit(fn -> File.rm(path) end)

    project = Reach.Project.from_sources([path], plugins: [Reach.Plugins.Phoenix])

    assert Enum.any?(MacroFact.collect_project(project), fn
             %MacroFact{
               kind: :phoenix_live_view_use,
               owner_module: MyAppWeb.PageLive,
               target: Phoenix.LiveView,
               data: %{resolved_from: {MyAppWeb, :live_view}}
             } ->
               true

             _fact ->
               false
           end)
  end

  test "explained callbacks only include high-confidence framework facts" do
    low_confidence = %MacroFact{
      kind: :macro_dsl_declaration,
      owner_module: MyApp.Mock,
      framework: nil,
      data: %{explained_callbacks: [{:run, 1}]},
      confidence: :low
    }

    high_confidence = %MacroFact{
      kind: :phoenix_live_component_use,
      owner_module: MyApp.Mock,
      framework: :phoenix,
      data: %{explained_callbacks: [{:render, 1}]},
      confidence: :high
    }

    assert MacroFact.explained_callbacks([low_confidence, high_confidence], MyApp.Mock) ==
             MapSet.new([{:render, 1}])
  end

  test "refines Phoenix LiveComponent use facts" do
    {:ok, facts} =
      MacroFact.collect_source(
        ~S'''
        defmodule MyAppWeb.ModalComponent do
          use Phoenix.LiveComponent
        end
        ''',
        plugins: [Reach.Plugins.Phoenix]
      )

    assert [
             %MacroFact{
               kind: :phoenix_live_component_use,
               framework: :phoenix,
               data: %{explained_callbacks: callbacks},
               confidence: :high
             }
           ] = facts

    assert :phoenix_live_component_use in MacroFact.kinds()
    assert {:handle_event, 3} in callbacks
    assert {:update, 2} in callbacks
  end

  test "collects facts from project files" do
    path = Path.join(System.tmp_dir!(), "reach-macro-fact-project-#{System.unique_integer()}.ex")

    File.write!(path, ~S'''
    defmodule MyAppWeb.Router do
      use Phoenix.Router
      get "/health", HealthController, :show
    end
    ''')

    on_exit(fn -> File.rm(path) end)

    project = Reach.Project.from_sources([path], plugins: [Reach.Plugins.Phoenix])

    assert [
             %MacroFact{kind: :phoenix_router_use, source: %{file: ^path}},
             %MacroFact{kind: :phoenix_route, source: %{file: ^path}}
           ] = MacroFact.collect_project(project)
  end

  test "collects behaviour declarations" do
    source = ~S'''
    defmodule MyApp.Implementation do
      @behaviour MyApp.Contract
    end
    '''

    assert {:ok,
            [
              %MacroFact{
                kind: :behaviour_declaration,
                owner_module: MyApp.Implementation,
                target: MyApp.Contract
              }
            ]} = MacroFact.collect_source(source)
  end

  test "collects broad map types from specs and callbacks" do
    source = ~S'''
    defmodule MyApp.Contract do
      @spec run(map(), integer()) :: :ok
      def run(_options, _count), do: :ok

      @callback handle(map()) :: :ok
    end
    '''

    assert {:ok, facts} = MacroFact.collect_source(source)

    assert Enum.any?(facts, fn
             %MacroFact{
               kind: :typespec_declaration,
               target: {MyApp.Contract, :run, 2},
               data: %{declaration_kind: :spec, broad_map_parameters: [0]}
             } ->
               true

             _fact ->
               false
           end)

    assert Enum.any?(facts, fn
             %MacroFact{
               kind: :typespec_declaration,
               target: {MyApp.Contract, :handle, 1},
               data: %{declaration_kind: :callback, broad_map_parameters: [0]}
             } ->
               true

             _fact ->
               false
           end)
  end

  test "keeps dynamic module names as nil instead of crashing" do
    source = ~S'''
    defmodule MyApp.Dynamic do
      use module
    end
    '''

    assert {:ok, [%MacroFact{name: :use, call_module: nil, target: nil}]} =
             MacroFact.collect_source(source)
  end
end
