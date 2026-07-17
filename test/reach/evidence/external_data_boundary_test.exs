defmodule Reach.Evidence.ExternalDataBoundaryTest do
  use ExUnit.Case, async: true

  alias Reach.Evidence.ExternalDataBoundary

  test "finds decoded data stored in persistent_term through a branch" do
    facts =
      collect(
        """
        defmodule PricingLeak do
          def init do
            pricing =
              case File.read("pricing.json") do
                {:ok, data} -> Jason.decode!(data)
                {:error, _reason} -> %{}
              end

            :persistent_term.put(:pricing, pricing)
          end

          def total(pricing), do: pricing["input"] + pricing["output"]
        end
        """,
        [Reach.Plugins.Jason]
      )

    assert [fact] = facts
    assert fact.source == "Jason.decode!/1"
    assert fact.source_line == 5
    assert fact.boundary == ":persistent_term.put/2"
    assert fact.boundary_kind == :storage
    assert fact.line == 9
    assert fact.boundary_function == {PricingLeak, :init, 0}
    assert fact.variables == [:pricing]
    assert fact.consumer_keys == ["input", "output"]
    assert fact.consumer_functions == [{PricingLeak, :total, 1}]
  end

  test "tracks successful tagged decoder results into ETS" do
    facts =
      collect(
        """
        defmodule TaggedDecodeLeak do
          def cache(raw) do
            payload =
              case Jason.decode(raw) do
                {:ok, decoded} -> decoded
                {:error, _reason} -> %{}
              end

            :ets.insert(:payloads, {:latest, payload})
          end
        end
        """,
        [Reach.Plugins.Jason]
      )

    assert [%{source: "Jason.decode/1", boundary: ":ets.insert/2"}] = facts
  end

  test "finds piped decoders crossing process boundaries" do
    facts =
      collect(
        """
        defmodule ProcessLeak do
          def dispatch(raw, server) do
            payload = raw |> Jason.decode!()
            GenServer.cast(server, payload)
          end
        end
        """,
        [Reach.Plugins.Jason]
      )

    assert [%{source: "Jason.decode!/1", boundary: "GenServer.cast/2", boundary_kind: :process}] =
             facts
  end

  test "stops provenance after explicit struct normalization" do
    facts =
      collect(
        """
        defmodule NormalizedPayload do
          defstruct [:id, :name]

          def cache(raw) do
            decoded = Jason.decode!(raw)
            payload = %__MODULE__{id: decoded["id"], name: decoded["name"]}
            :persistent_term.put(:payload, payload)
          end
        end
        """,
        [Reach.Plugins.Jason]
      )

    assert facts == []
  end

  test "tracks decoder bindings through with" do
    facts =
      collect(
        """
        defmodule WithLeak do
          def cache(raw) do
            with {:ok, decoded} <- Jason.decode(raw) do
              :persistent_term.put(:payload, decoded)
            end
          end
        end
        """,
        [Reach.Plugins.Jason]
      )

    assert [%{source: "Jason.decode/1", boundary: ":persistent_term.put/2"}] = facts
  end

  test "finds decoded data returned as GenServer state" do
    facts =
      collect(
        """
        defmodule StateLeak do
          use GenServer

          def init(raw) do
            decoded = Jason.decode!(raw)
            {:ok, decoded}
          end
        end
        """,
        [Reach.Plugins.Jason]
      )

    assert [
             %{
               source: "Jason.decode!/1",
               boundary: "GenServer.init/1 ok state return",
               boundary_kind: :process,
               line: 6
             }
           ] = facts
  end

  test "does not apply GenServer callback semantics across modules in one file" do
    facts =
      collect(
        """
        defmodule ActualServer do
          use GenServer
          def init(state), do: {:ok, state}
        end

        defmodule OrdinaryParser do
          def init(raw), do: {:ok, Jason.decode!(raw)}
        end
        """,
        [Reach.Plugins.Jason]
      )

    assert facts == []
  end

  test "does not infer decoder provenance without the owning plugin" do
    facts =
      collect(
        """
        defmodule NoDecoderPlugin do
          def cache(raw) do
            decoded = Jason.decode!(raw)
            :persistent_term.put(:payload, decoded)
          end
        end
        """,
        []
      )

    assert facts == []
  end

  test "supports Poison-owned decoder provenance" do
    facts =
      collect(
        """
        defmodule PoisonLeak do
          def cache(raw) do
            decoded = Poison.decode!(raw)
            Process.put(:payload, decoded)
          end
        end
        """,
        [Reach.Plugins.Poison]
      )

    assert [%{source: "Poison.decode!/1", boundary: "Process.put/2"}] = facts
  end

  defp collect(source, plugins) do
    {:ok, ast} = Code.string_to_quoted(source, columns: true)
    ExternalDataBoundary.collect_ast(ast, "lib/sample.ex", plugins)
  end
end
