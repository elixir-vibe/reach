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
        def consume(entity), do: entity
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

  defp collect(source) do
    path = Path.join(System.tmp_dir!(), "reach-shape-#{System.unique_integer([:positive])}.ex")
    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)

    path
    |> List.wrap()
    |> Project.from_sources()
    |> ParameterShape.collect_project()
  end
end
