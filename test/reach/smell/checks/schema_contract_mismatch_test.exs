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

  defp project_from_source(source) do
    path = Path.join(System.tmp_dir!(), "reach-schema-mismatch-#{System.unique_integer()}.ex")
    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)
    Project.from_sources([path], plugins: [Reach.Plugins.Zoi])
  end
end
