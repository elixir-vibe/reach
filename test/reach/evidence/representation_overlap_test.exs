defmodule Reach.Evidence.RepresentationOverlapTest do
  use ExUnit.Case, async: true

  alias Reach.Evidence.RepresentationOverlap
  alias Reach.Project

  test "collects cross-module struct and bare-map overlaps with context" do
    facts =
      collect("""
      defmodule Domain.User do
        defstruct [:id, :name, :email, :role]
      end

      defmodule Importer do
        def build_user(attrs) do
          user = %{id: attrs.id, name: attrs.name, email: attrs.email, role: attrs.role}
          user
        end
      end

      defmodule UserView do
        def render(user) do
          %{id: user.id, name: user.name, email: user.email, role: user.role}
        end
      end

      defmodule UserFactory do
        def build(attrs) do
          Domain.User.new!(%{id: attrs.id, name: attrs.name, email: attrs.email, role: attrs.role})
        end
      end
      """)

    importer = Enum.find(facts, &(&1.map.module == Importer))
    view = Enum.find(facts, &(&1.map.module == UserView))
    factory = Enum.find(facts, &(&1.map.module == UserFactory))

    assert importer.struct.module == Domain.User
    assert importer.similarity == 1.0
    assert importer.name_match?
    assert importer.map.projection?
    assert importer.map.projection_sources == [:attrs]
    assert importer.map.role == :domain

    assert view.map.projection?
    assert view.map.projection_sources == [:user]
    assert view.map.role == :presentation

    assert factory.map.normalized_into == Domain.User
  end

  test "resolves nested struct modules" do
    facts =
      collect("""
      defmodule Container do
        defmodule Entry do
          defstruct [:id, :name, :value]
        end
      end

      defmodule EntryBuilder do
        def build_entry(attrs), do: %{id: attrs.id, name: attrs.name, value: attrs.value}
      end
      """)

    assert [%{struct: %{module: Container.Entry}}] = facts
  end

  test "resolves __MODULE__ nested struct modules" do
    facts =
      collect("""
      defmodule Container do
        defmodule __MODULE__.Resolution do
          defstruct [:id, :name, :value]
        end
      end

      defmodule ResolutionBuilder do
        def build_resolution(attrs), do: %{id: attrs.id, name: attrs.name, value: attrs.value}
      end
      """)

    assert [%{struct: %{module: Container.Resolution}}] = facts
  end

  test "requires near-equivalent shapes and excludes map patterns" do
    facts =
      collect("""
      defmodule Domain.Account do
        defstruct [:id, :name, :email, :status, :role]
      end

      defmodule Reader do
        def read(%{id: id, name: name, email: email, other: other}) do
          %{id: id, name: name, email: email, other: other}
        end
      end
      """)

    assert facts == []
  end

  defp collect(source) do
    path =
      Path.join(
        System.tmp_dir!(),
        "reach-representation-#{System.unique_integer([:positive])}.ex"
      )

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)

    path
    |> List.wrap()
    |> Project.from_sources()
    |> RepresentationOverlap.collect_project()
  end
end
