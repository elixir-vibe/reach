defmodule Reach.Smell.Checks.BroadMapContractTest do
  use ExUnit.Case, async: true

  alias Reach.Check.Smells
  alias Reach.Project

  test "flags broad map parameters with a strict fixed shape" do
    findings =
      project_from_source("""
      defmodule Contract do
        @spec metadata(map()) :: tuple()
        def metadata(data) do
          {Map.fetch!(data, :id), Map.fetch!(data, :name), Map.fetch!(data, :type)}
        end
      end
      """)
      |> Smells.run()

    assert [
             %{
               kind: :broad_map_contract,
               keys: ["id", "name", "type"],
               message: message
             }
           ] = Enum.filter(findings, &(&1.kind == :broad_map_contract))

    assert message =~ "parameter 1"
    assert message =~ "uses strict access"
  end

  test "does not promote a lenient fixed shape" do
    findings =
      project_from_source("""
      defmodule Contract do
        @spec metadata(map()) :: tuple()
        def metadata(data) do
          {Map.get(data, :id), Map.get(data, :name), Map.get(data, :type)}
        end
      end
      """)
      |> Smells.run()

    refute Enum.any?(findings, &(&1.kind == :broad_map_contract))
  end

  test "does not attribute keys from a derived nested map to the broad parameter" do
    findings =
      project_from_source("""
      defmodule Contract do
        @spec metadata(map()) :: tuple()
        def metadata(data) do
          nested = Map.fetch!(data, :nested)
          {Map.fetch!(nested, :id), Map.fetch!(nested, :name), Map.fetch!(nested, :type)}
        end
      end
      """)
      |> Smells.run()

    refute Enum.any?(findings, &(&1.kind == :broad_map_contract))
  end

  test "does not attribute a nested pattern binding to the outer broad parameter" do
    findings =
      project_from_source("""
      defmodule Contract do
        @spec execute(map()) :: tuple()
        def execute(%{config: config}) do
          {Map.fetch!(config, :id), Map.fetch!(config, :name), Map.fetch!(config, :type)}
        end
      end
      """)
      |> Smells.run()

    refute Enum.any?(findings, &(&1.kind == :broad_map_contract))
  end

  test "retains a direct alias around a map pattern" do
    findings =
      project_from_source("""
      defmodule Contract do
        @spec metadata(map()) :: tuple()
        def metadata(%{kind: :record} = data) do
          {Map.fetch!(data, :id), Map.fetch!(data, :name), Map.fetch!(data, :type)}
        end
      end
      """)
      |> Smells.run()

    assert [%{kind: :broad_map_contract}] =
             Enum.filter(findings, &(&1.kind == :broad_map_contract))
  end

  test "matches strict accesses to the correct broad parameter" do
    findings =
      project_from_source("""
      defmodule Contract do
        @spec metadata(term(), map()) :: tuple()
        def metadata(_context, data) do
          {Map.fetch!(data, :id), Map.fetch!(data, :name), Map.fetch!(data, :type)}
        end
      end
      """)
      |> Smells.run()

    assert [%{kind: :broad_map_contract, message: message}] =
             Enum.filter(findings, &(&1.kind == :broad_map_contract))

    assert message =~ "parameter 2"
  end

  test "does not promote a strict clause when the parameter has another observed shape" do
    findings =
      project_from_source("""
      defmodule Contract do
        @spec metadata(map()) :: tuple()
        def metadata(%{kind: :person} = data) do
          {Map.fetch!(data, :id), Map.fetch!(data, :name), Map.fetch!(data, :email)}
        end

        def metadata(%{kind: :event} = data) do
          {Map.get(data, :id), Map.get(data, :name), Map.get(data, :time)}
        end
      end
      """)
      |> Smells.run()

    refute Enum.any?(findings, &(&1.kind == :broad_map_contract))
  end

  test "does not flag broad maps without enough observed shape evidence" do
    findings =
      project_from_source("""
      defmodule Contract do
        @spec value(map()) :: term()
        def value(data), do: Map.fetch!(data, :value)
      end
      """)
      |> Smells.run()

    refute Enum.any?(findings, &(&1.kind == :broad_map_contract))
  end

  test "does not flag explicit map types" do
    findings =
      project_from_source("""
      defmodule Contract do
        @spec metadata(%{id: term(), name: term(), type: term()}) :: tuple()
        def metadata(data) do
          {Map.fetch!(data, :id), Map.fetch!(data, :name), Map.fetch!(data, :type)}
        end
      end
      """)
      |> Smells.run()

    refute Enum.any?(findings, &(&1.kind == :broad_map_contract))
  end

  defp project_from_source(source) do
    path = Path.join(System.tmp_dir!(), "reach-broad-map-#{System.unique_integer()}.ex")
    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)
    Project.from_sources([path], plugins: [])
  end
end
