defmodule Reach.Smell.Checks.SchemaContractMismatchTest do
  use ExUnit.Case, async: true

  alias Reach.Check.Smells
  alias Reach.Project

  test "flags schemas that mix atom and string field keys" do
    findings =
      project_from_source("""
      defmodule Contract do
        def schema do
          Zoi.object(%{:name => Zoi.string(), "count" => Zoi.integer()})
        end
      end
      """)
      |> Smells.run()

    assert Enum.any?(findings, &(&1.kind == :mixed_schema_key_representation))
  end

  test "joins validator inputs to observed map access" do
    findings =
      project_from_source(
        """
        defmodule Contract do
          @schema [name: [type: :string, required: true], count: [type: :integer]]

          def validate(input) do
            Map.get(input, :missing)
            Map.get(input, "name", "anonymous")
            NimbleOptions.validate(input, @schema)
          end
        end
        """,
        [Reach.Plugins.NimbleOptions]
      )
      |> Smells.run()

    assert Enum.any?(findings, &(&1.kind == :schema_undeclared_key_access))
    assert Enum.any?(findings, &(&1.kind == :schema_key_representation_mismatch))
    assert Enum.any?(findings, &(&1.kind == :required_schema_key_default))
  end

  test "sorts grouped schema keys and evidence deterministically" do
    findings =
      project_from_source(
        """
        defmodule Contract do
          @schema [name: [type: :string]]

          def validate(input) do
            Map.get(input, :zeta)
            Map.get(input, :alpha)
            Map.get(input, :middle)
            NimbleOptions.validate(input, @schema)
          end
        end
        """,
        [Reach.Plugins.NimbleOptions]
      )
      |> Smells.run()

    assert [finding] = Enum.filter(findings, &(&1.kind == :schema_undeclared_key_access))
    assert finding.keys == ["alpha", "middle", "zeta"]
    assert finding.message =~ ~s("alpha", "middle", "zeta")

    assert Enum.map(finding.evidence, &(&1 |> String.split(":") |> List.last())) == [
             "6",
             "7",
             "5"
           ]
  end

  test "does not join access from a different value" do
    findings =
      project_from_source(
        """
        defmodule Contract do
          @schema [name: [type: :string, required: true]]

          def validate(input, metadata) do
            Map.get(metadata, "missing")
            NimbleOptions.validate(input, @schema)
          end
        end
        """,
        [Reach.Plugins.NimbleOptions]
      )
      |> Smells.run()

    refute Enum.any?(findings, &(&1.kind == :schema_undeclared_key_access))
  end

  test "does not treat wildcard schema keys as undeclared" do
    findings =
      project_from_source(
        """
        defmodule Contract do
          @schema [*: [type: :keyword_list]]

          def validate(sections, section) do
            sections = NimbleOptions.validate!(sections, @schema)
            sections[section]
          end
        end
        """,
        [Reach.Plugins.NimbleOptions]
      )
      |> Smells.run()

    refute Enum.any?(findings, &(&1.kind == :schema_undeclared_key_access))
  end

  test "expands schema fragments stored in module attributes" do
    findings =
      project_from_source(
        """
        defmodule Contract do
          @request_opts {:request_opts, [type: :keyword_list, default: []]}
          @schema [@request_opts, batch_size: [type: :pos_integer]]

          def validate(opts) do
            opts = NimbleOptions.validate!(opts, @schema)
            opts[:request_opts]
          end
        end
        """,
        [Reach.Plugins.NimbleOptions]
      )
      |> Smells.run()

    refute Enum.any?(findings, &(&1.kind == :schema_undeclared_key_access))
  end

  test "does not attribute nested or revalidated values to the outer schema" do
    findings =
      project_from_source(
        """
        defmodule Contract do
          @schema [nested: [type: :keyword_list], smoke: [type: :keyword_list]]
          @smoke_schema [enabled: [type: :boolean], entry_file: [type: :string]]

          def validate(opts) do
            opts = NimbleOptions.validate!(opts, @schema)
            nested = opts[:nested]
            Map.get(nested, :implementation_specific)
            smoke = NimbleOptions.validate!(opts[:smoke], @smoke_schema)
            {smoke[:enabled], smoke[:entry_file]}
          end
        end
        """,
        [Reach.Plugins.NimbleOptions]
      )
      |> Smells.run()

    refute Enum.any?(findings, &(&1.kind == :schema_undeclared_key_access))
  end

  test "does not flag schemas with one key representation" do
    findings =
      project_from_source("""
      defmodule Contract do
        def schema, do: Zoi.object(%{name: Zoi.string(), count: Zoi.integer()})
      end
      """)
      |> Smells.run()

    refute Enum.any?(findings, &(&1.kind == :mixed_schema_key_representation))
  end

  defp project_from_source(source, plugins \\ [Reach.Plugins.Zoi]) do
    path = Path.join(System.tmp_dir!(), "reach-schema-mismatch-#{System.unique_integer()}.ex")
    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)
    Project.from_sources([path], plugins: plugins)
  end
end
