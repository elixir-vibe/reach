defmodule Reach.Evidence.ReturnContractTest do
  use ExUnit.Case, async: true

  alias Reach.Evidence.ReturnContract

  test "collects terminal shapes across clauses and branches" do
    facts =
      collect("""
      defmodule ReturnEvidence do
        def parse(:empty), do: :ok
        def parse(value), do: {:ok, value}

        def load(value) do
          case value do
            :raw -> %{value: value}
            :tagged -> {:ok, value}
          end
        end
      end
      """)

    parse = Enum.find(facts, &(&1.function == :parse))
    assert parse.module == ReturnEvidence
    assert parse.arity == 1
    assert parse.line == 2
    assert Enum.map(parse.outcomes, & &1.shape) == [{:bare_atom, :ok}, {:tagged, :ok, 2}]

    load = Enum.find(facts, &(&1.function == :load))
    assert Enum.map(load.outcomes, & &1.class) == [:map, :tagged]
    assert Enum.map(load.outcomes, & &1.line) == [7, 8]
  end

  test "records nested identical tags and dynamic with fallthrough" do
    facts =
      collect("""
      defmodule ReturnDetails do
        def nested(value), do: {:ok, {:ok, value}}

        def decode(raw) do
          with {:ok, value} <- parse(raw) do
            {:ok, value}
          end
        end
      end
      """)

    nested = Enum.find(facts, &(&1.function == :nested))
    dynamic = Enum.find(facts, &(&1.function == :decode))
    assert [%{nested_same_tag: :ok}] = nested.outcomes
    assert Enum.any?(dynamic.outcomes, &(&1.class == :dynamic))
  end

  test "classifies nested __MODULE__ struct aliases without crashing" do
    [fact] =
      collect("""
      defmodule DynamicStructReturn do
        def build, do: %__MODULE__.Result{}
      end
      """)

    assert [%{class: :struct, shape: {:struct, "__MODULE__.Result"}}] = fact.outcomes
  end

  test "marks source-declared OTP callbacks for policy filtering" do
    [fact] =
      collect("""
      defmodule LegacyServer do
        use GenServer
        def init(:fast), do: {:ok, %{}}
        def init(:slow), do: {:ok, %{}, 1_000}
      end
      """)

    assert fact.function == :init
    assert fact.impl
  end

  test "marks @impl functions for policy filtering" do
    [fact] =
      collect("""
      defmodule CallbackReturns do
        @impl true
        def handle_call(:read, _from, state), do: {:reply, state, state}
        def handle_call(:stop, _from, state), do: {:stop, :normal, state}
      end
      """)

    assert fact.function == :handle_call
    assert fact.impl
  end

  defp collect(source) do
    {:ok, ast} = Code.string_to_quoted(source, columns: true)
    ReturnContract.collect_ast(ast, "lib/sample.ex")
  end
end
