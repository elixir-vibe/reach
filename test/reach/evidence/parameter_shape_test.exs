defmodule Reach.Evidence.ParameterShapeTest do
  use ExUnit.Case, async: true

  alias Reach.Evidence.ParameterShape
  alias Reach.Project

  test "collects map variants flowing from distinct callers" do
    [fact] =
      collect("""
      defmodule ShapeFlow do
        def first, do: consume(%{id: 1, name: "A", email: "a@example.com"})
        def second, do: consume(%{id: 2, status: :active, role: :admin})
        def consume(entity), do: {entity.name, Map.get(entity, :status)}
      end
      """)

    assert fact.target == {ShapeFlow, :consume, 1}
    assert fact.parameter == :entity
    assert fact.parameter_index == 0
    assert fact.role == :domain
    assert fact.core_keys == [:id]
    assert fact.union_keys == [:email, :id, :name, :role, :status]
    assert fact.optional_keys == [:email, :name, :role, :status]
    assert fact.entropy == 0.8
    assert length(fact.callers) == 2
    assert length(fact.variants) == 2
    assert fact.strict_consumed_keys == [:name]
    assert fact.defensive_consumed_keys == [:status]
  end

  test "follows map values through local assignments" do
    [fact] =
      collect("""
      defmodule AssignedShapes do
        def first do
          value = %{id: 1, name: "A", email: "a@example.com"}
          consume(value)
        end

        def second do
          value = %{id: 2, status: :active, role: :admin}
          consume(value)
        end

        def consume(entity), do: entity
      end
      """)

    assert fact.target == {AssignedShapes, :consume, 1}
    assert length(fact.occurrences) == 2
  end

  test "marks literal companion-argument dispatch" do
    [fact] =
      collect("""
      defmodule CompanionDispatch do
        def first, do: log(:started, %{id: 1, name: "A"})
        def second, do: log(:finished, %{id: 2, status: :done})

        def log(event, data) do
          case event do
            :started -> data.name
            :finished -> data.status
          end
        end
      end
      """)

    assert fact.companion_dispatch?
  end

  test "does not treat partial caller patterns as exact map origins" do
    assert [] =
             collect("""
             defmodule PartialPatterns do
               def first(%{conn: _conn, chan: _chan} = stream), do: send_eof(stream)
               def second(%{data: _data} = stream), do: send_eof(stream)
               def send_eof(stream), do: {stream.conn, stream.chan}
             end
             """)
  end

  test "does not treat literal-only function-head maps as exact origins" do
    assert [] =
             collect("""
             defmodule LiteralPatterns do
               def first(%{kind: :first, id: 1, name: "A"} = input), do: consume(input)
               def second(%{kind: :second, id: 2, status: :done} = input), do: consume(input)
               def consume(input), do: {input.id, input.name, input.status}
             end
             """)
  end

  test "marks struct and guarded-map clause dispatch" do
    [fact] =
      collect("""
      defmodule GuardedMapDispatch do
        defmodule Spec do
          defstruct [:kind, :name, :metadata]
        end

        def first, do: matches?(%{kind: :tool, name: "run"})
        def second, do: matches?(%{kind: :tool, name: "run", metadata: %{safe: true}})

        def matches?(%Spec{} = operation), do: matches?(Map.from_struct(operation))
        def matches?(operation) when is_map(operation), do: operation.name
      end
      """)

    assert fact.intentional_dispatch?
  end

  test "marks explicit multi-clause dispatch and non-contract parameter roles" do
    facts =
      collect("""
      defmodule IntentionalShapes do
        def first, do: dispatch(%{type: :user, id: 1, name: "A"})
        def second, do: dispatch(%{type: :team, id: 2, members: []})

        def dispatch(%{type: :user} = params), do: params
        def dispatch(%{type: :team} = params), do: params
      end
      """)

    assert [fact] = facts
    assert fact.intentional_dispatch?
    assert fact.tagged_variants?
    assert fact.parameter == :params
    assert fact.role == :non_contract
  end

  test "supports target functions without module metadata" do
    facts =
      collect(
        """
        defmodule ModulelessShapeTarget do
          def first(value), do: consume(%{id: value, name: "first"})
          def second(value), do: consume(%{id: value, status: :active})
          def consume(params), do: params
        end
        """,
        without_module: :consume
      )

    assert [%{target: {nil, :consume, 1}}] = facts
  end

  defp collect(source, opts \\ []) do
    path = Path.join(System.tmp_dir!(), "reach-shape-#{System.unique_integer([:positive])}.ex")
    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)

    project = Project.from_sources([path])

    project =
      case opts[:without_module] do
        nil -> project
        name -> delete_function_module(project, name)
      end

    ParameterShape.collect_project(project)
  end

  defp delete_function_module(project, name) do
    {id, _function} =
      Enum.find(project.nodes, fn {_id, node} ->
        node.type == :function_def and node.meta[:name] == name
      end)

    nodes =
      Map.update!(project.nodes, id, fn function ->
        %{function | meta: Map.delete(function.meta, :module)}
      end)

    %{project | nodes: nodes}
  end
end
