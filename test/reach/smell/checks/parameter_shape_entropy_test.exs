defmodule Reach.Smell.Checks.ParameterShapeEntropyTest do
  use ExUnit.Case, async: true

  alias Reach.Check.Smells
  alias Reach.Project

  test "reports divergent domain map shapes from distinct callers" do
    findings =
      smells("""
      defmodule GrabBagContract do
        def user_caller, do: process(%{id: 1, name: "A", email: "a@example.com"})
        def status_caller, do: process(%{id: 2, status: :active, role: :admin})

        def process(entity), do: {entity.id, entity.name, entity.status}
      end
      """)

    assert [finding] = by_kind(findings)
    assert finding.confidence == :medium
    assert finding.message =~ "GrabBagContract.process/1 parameter entity"
    assert finding.message =~ "2 divergent map shapes from 2 callers"
    assert finding.keys == ["email", "id", "name", "role", "status"]
    assert finding.evidence |> List.first() =~ "core_keys=[:id]"
    assert Enum.any?(finding.evidence, &String.starts_with?(&1, "suggestion=introduce a struct"))
  end

  test "retains incompatible classifier schemas with strict shape-specific reads" do
    findings =
      smells("""
      defmodule DivergentClassifier do
        def first, do: classify(%{score: 0.9, coordination: 0.8, synthesis: 0.7})
        def second, do: classify(%{behavioral: 0.9, cognitive: 0.8, social: 0.7})

        def classify(indicators) do
          cond do
            Map.has_key?(indicators, :score) and indicators.score > 0.8 -> :strong
            Map.has_key?(indicators, :coordination) and indicators.coordination > 0.7 -> :coordinated
            true -> :weak
          end
        end
      end
      """)

    assert [finding] = by_kind(findings)
    assert finding.message =~ "DivergentClassifier.classify/1"
  end

  test "excludes options, tagged variants, and explicit clause dispatch" do
    findings =
      smells("""
      defmodule IntentionalContracts do
        def first, do: configure(%{timeout: 10, retries: 2, mode: :safe})
        def second, do: configure(%{pool: 4, queue: 20, strategy: :fifo})

        def configure(opts) do
          Map.get(opts, :timeout)
          Map.get(opts, :pool)
        end

        def user, do: dispatch(%{type: :user, id: 1, name: "A"})
        def team, do: dispatch(%{type: :team, id: 2, members: []})

        def dispatch(%{type: :user} = entity), do: Map.get(entity, :name)
        def dispatch(%{type: :team} = entity), do: Map.get(entity, :members)
      end
      """)

    assert by_kind(findings) == []
  end

  test "excludes intentionally optional keys consumed with defensive access" do
    findings =
      smells("""
      defmodule DefensiveOptionalFields do
        def first, do: process(%{records: []})
        def second, do: process(%{records: [], variables: %{}, metadata: %{}})

        def process(result) do
          {
            Map.get(result, :records, []),
            Map.get(result, :variables, %{}),
            Map.get(result, :metadata, %{})
          }
        end
      end
      """)

    assert by_kind(findings) == []
  end

  test "excludes shapes selected by a literal companion argument" do
    findings =
      smells("""
      defmodule CompanionShapeDispatch do
        def first, do: log(:started, %{id: 1, name: "A", email: "a@example.com"})
        def second, do: log(:finished, %{id: 2, status: :done, reason: :normal})

        def log(event, data) do
          case event do
            :started -> data.name
            :finished -> data.status
          end
        end
      end
      """)

    assert by_kind(findings) == []
  end

  test "does not exclude correlated literals when the callee does not dispatch on them" do
    findings =
      smells("""
      defmodule CorrelatedButIgnored do
        def first, do: process(:legacy, %{id: 1, name: "A", email: "a@example.com"})
        def second, do: process(:modern, %{id: 2, status: :active, role: :admin})

        def process(_version, entity), do: {entity.id, entity.name, entity.status}
      end
      """)

    assert [_finding] = by_kind(findings)
  end

  test "requires the callee to consume keys that vary between shapes" do
    findings =
      smells("""
      defmodule CompatibleSupersets do
        def first, do: process(%{line: 1, column: 2})
        def second, do: process(%{line: 3, column: 4, tag_name: "div", inner_location: 5})

        def process(meta) do
          Map.get(meta, :line)
          Map.get(meta, :column)
        end
      end
      """)

    assert by_kind(findings) == []
  end

  test "requires distinct calling functions rather than repeated calls in one caller" do
    findings =
      smells("""
      defmodule OneCaller do
        def run do
          process(%{id: 1, name: "A", email: "a@example.com"})
          process(%{id: 2, status: :active, role: :admin})
        end

        def process(entity), do: {entity.id, entity.name, entity.status}
      end
      """)

    assert by_kind(findings) == []
  end

  test "requires the callee to consume multiple contract keys" do
    findings =
      smells("""
      defmodule TransportOnly do
        def first, do: send_value(%{id: 1, name: "A", email: "a@example.com"})
        def second, do: send_value(%{id: 2, status: :active, role: :admin})
        def send_value(entity), do: Other.send(entity)
      end
      """)

    assert by_kind(findings) == []
  end

  test "supports source suppression" do
    findings =
      smells("""
      defmodule SuppressedShapeEntropy do
        def first, do: process(%{id: 1, name: "A", email: "a@example.com"})
        def second, do: process(%{id: 2, status: :active, role: :admin})

        # reach:disable-next-line parameter_shape_entropy -- compatibility boundary
        def process(entity), do: {entity.id, entity.name, entity.status}
      end
      """)

    assert by_kind(findings) == []
  end

  defp by_kind(findings), do: Enum.filter(findings, &(&1.kind == :parameter_shape_entropy))

  defp smells(source, config \\ []) do
    path = Path.join(System.tmp_dir!(), "reach-entropy-#{System.unique_integer([:positive])}.ex")
    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)

    path
    |> List.wrap()
    |> Project.from_sources()
    |> Smells.run(config)
  end
end
