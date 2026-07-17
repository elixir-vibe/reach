defmodule Reach.Smell.Checks.SameEntityRepresentationTest do
  use ExUnit.Case, async: true

  alias Reach.Check.Smells
  alias Reach.Project

  test "groups bare maps that duplicate an existing struct" do
    findings =
      smells("""
      defmodule Domain.Page do
        defstruct [:rows, :page, :page_size, :total, :total_pages, :meta, :error]
      end

      defmodule PageLoader do
        def rows_page(rows) do
          %{rows: rows, page: 1, page_size: 25, total: length(rows), total_pages: 1, meta: %{}}
        end

        def error_page(error) do
          %{rows: [], page: 1, page_size: 25, total: 0, total_pages: 1, error: error}
        end
      end
      """)

    assert [finding] = by_kind(findings)
    assert finding.confidence == :medium
    assert finding.message =~ "PageLoader constructs bare maps"
    assert finding.message =~ "Domain.Page"
    assert finding.occurrences == 2
    assert "rows" in finding.keys
    assert length(finding.evidence) == 3
  end

  test "excludes direct projections, presentation maps, and immediate struct normalization" do
    findings =
      smells("""
      defmodule Domain.User do
        defstruct [:id, :name, :email, :role]
      end

      defmodule UserView do
        def project(user), do: %{id: user.id, name: user.name, email: user.email, role: user.role}

        def render_user(attrs) do
          %{id: attrs.id, name: attrs.name, email: attrs.email, role: attrs.role}
        end
      end

      defmodule UserFactory do
        def build_user(attrs) do
          Domain.User.new!(%{id: attrs.id, name: attrs.name, email: attrs.email, role: attrs.role})
        end
      end
      """)

    assert by_kind(findings) == []
  end

  test "excludes structs with an explicit outbound map conversion" do
    findings =
      smells("""
      defmodule Domain.Snapshot do
        defstruct [:id, :name, :value]
        def to_map(snapshot), do: %{id: snapshot.id, name: snapshot.name, value: snapshot.value}
      end

      defmodule SnapshotBuilder do
        def build_snapshot(attrs), do: %{id: attrs.id, name: attrs.name, value: attrs.value}
      end
      """)

    assert by_kind(findings) == []
  end

  test "requires entity-name evidence by default" do
    findings =
      smells("""
      defmodule Domain.Profile do
        defstruct [:id, :name, :email, :role]
      end

      defmodule Importer do
        def build(attrs), do: %{id: attrs.id, name: attrs.name, email: attrs.email, role: attrs.role}
      end
      """)

    assert by_kind(findings) == []
  end

  test "allows entity-name matching to be relaxed through config" do
    findings =
      smells(
        """
        defmodule Domain.Profile do
          defstruct [:id, :name, :email, :role]
        end

        defmodule Importer do
          def build(attrs), do: %{id: attrs.id, name: attrs.name, email: attrs.email, role: attrs.role}
        end
        """,
        smells: [representation_overlap: [require_name_match: false]]
      )

    assert [_finding] = by_kind(findings)
  end

  test "supports source suppression" do
    findings =
      smells("""
      defmodule Domain.Account do
        defstruct [:id, :name, :email, :role]
      end

      defmodule AccountImport do
        # reach:disable-next-line same_entity_representation -- legacy boundary representation
        def build_account(attrs), do: %{id: attrs.id, name: attrs.name, email: attrs.email, role: attrs.role}
      end
      """)

    assert by_kind(findings) == []
  end

  defp by_kind(findings), do: Enum.filter(findings, &(&1.kind == :same_entity_representation))

  defp smells(source, config \\ []) do
    path =
      Path.join(System.tmp_dir!(), "reach-same-entity-#{System.unique_integer([:positive])}.ex")

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)

    path
    |> List.wrap()
    |> Project.from_sources()
    |> Smells.run(config)
  end
end
