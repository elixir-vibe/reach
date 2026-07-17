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

    assert factory.map.normalized_into == {:call, Domain.User, :new!}
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

  test "recognizes nested field projections" do
    [fact] =
      collect("""
      defmodule Domain.Cursor do
        defstruct [:position, :visible, :style, :blink_state]
      end

      defmodule CursorSnapshot do
        def get_cursor_state(emulator) do
          %{
            position: emulator.cursor.position,
            visible: emulator.cursor.visible,
            style: emulator.cursor.style,
            blink_state: emulator.cursor.blink_state
          }
        end
      end
      """)

    assert fact.map.projection?
    assert fact.map.projection_sources == [:cursor]
  end

  test "tracks maps normalized through local struct construction" do
    [fact] =
      collect("""
      defmodule Domain.Session do
        defstruct [:id, :name, :status]
      end

      defmodule SessionLoader do
        def load(attrs) do
          session = %{id: attrs.id, name: attrs.name, status: attrs.status}
          struct(Domain.Session, session)
        end
      end
      """)

    assert fact.map.normalized_into == :struct_constructor
  end

  test "tracks helper return maps normalized by all callers" do
    [fact] =
      collect("""
      defmodule Domain.Profile do
        defstruct [:id, :name, :status]
        def new!(attrs), do: struct!(__MODULE__, attrs)
      end

      defmodule ProfileLoader do
        def load(attrs), do: Domain.Profile.new!(profile_fields(attrs))

        defp profile_fields(attrs) do
          %{id: attrs.id, name: attrs.name, status: attrs.status}
        end
      end
      """)

    assert fact.map.normalized_into == {:call, Domain.Profile, :new!}
  end

  test "does not infer helper normalization when any caller keeps the map" do
    [fact] =
      collect("""
      defmodule Domain.Profile do
        defstruct [:id, :name, :status]
        def new!(attrs), do: struct!(__MODULE__, attrs)
      end

      defmodule ProfileLoader do
        def load(attrs), do: Domain.Profile.new!(profile_fields(attrs))
        def raw(attrs), do: profile_fields(attrs)

        defp profile_fields(attrs) do
          %{id: attrs.id, name: attrs.name, status: attrs.status}
        end
      end
      """)

    assert is_nil(fact.map.normalized_into)
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

  test "excludes literal-only function-head patterns and explicit __struct__ maps" do
    facts =
      collect("""
      defmodule Domain.Color do
        defstruct [:red, :green, :blue]
      end

      defmodule ColorCompatibility do
        def black?(%{red: 0, green: 0, blue: 0}), do: true
        def black?(_color), do: false

        def generated do
          %{__struct__: Domain.Color, red: 1, green: 2, blue: 3}
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
