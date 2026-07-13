defmodule Reach.Smell.Checks.BroadCallbackMapContractTest do
  use ExUnit.Case, async: true

  alias Reach.Check.Smells
  alias Reach.Project

  test "flags broad callback maps with a stable shape across implementations" do
    findings =
      project_from_sources([
        """
        defmodule Contract do
          @callback metadata(map()) :: tuple()
        end
        """,
        implementation("First"),
        implementation("Second")
      ])
      |> Smells.run()

    assert [%{kind: :broad_callback_map_contract, keys: ["id", "name", "type"]}] =
             Enum.filter(findings, &(&1.kind == :broad_callback_map_contract))
  end

  test "accepts use declarations as implementation relationships" do
    findings =
      project_from_sources([
        """
        defmodule Contract do
          defmacro __using__(_opts), do: quote(do: :ok)
          @callback metadata(map()) :: tuple()
        end
        """,
        """
        defmodule UsedImplementation do
          use Contract
          def metadata(data) do
            {Map.get(data, :id), Map.get(data, :name), Map.get(data, :type),
             Map.get(data, :status), Map.get(data, :version)}
          end
        end
        """
      ])
      |> Smells.run()

    assert Enum.any?(findings, &(&1.kind == :broad_callback_map_contract))
  end

  test "does not promote weak evidence from one implementation" do
    findings =
      project_from_sources([
        """
        defmodule Contract do
          @callback metadata(map()) :: tuple()
        end
        """,
        implementation("Only")
      ])
      |> Smells.run()

    refute Enum.any?(findings, &(&1.kind == :broad_callback_map_contract))
  end

  defp implementation(name) do
    """
    defmodule #{name} do
      @behaviour Contract
      def metadata(data) do
        {Map.get(data, :id), Map.get(data, :name), Map.get(data, :type)}
      end
    end
    """
  end

  defp project_from_sources(sources) do
    directory = Path.join(System.tmp_dir!(), "reach-callback-#{System.unique_integer()}")
    File.mkdir_p!(directory)

    paths =
      sources
      |> Enum.with_index()
      |> Enum.map(fn {source, index} ->
        path = Path.join(directory, "source_#{index}.ex")
        File.write!(path, source)
        path
      end)

    on_exit(fn -> File.rm_rf!(directory) end)
    Project.from_sources(paths, plugins: [])
  end
end
