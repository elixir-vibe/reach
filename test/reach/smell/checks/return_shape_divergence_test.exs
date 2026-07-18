defmodule Reach.Smell.Checks.ReturnShapeDivergenceTest do
  use ExUnit.Case, async: true

  alias Reach.Check.Smells
  alias Reach.Project

  test "finds a bare tag mixed with the same tagged contract" do
    findings =
      smells("""
      defmodule MixedSuccess do
        @spec parse(atom()) :: {:ok, atom()}
        def parse(:empty), do: :ok
        def parse(value), do: {:ok, value}
      end
      """)

    assert [finding] = by_kind(findings, :return_shape_divergence)
    assert finding.confidence == :high
    assert finding.location =~ ":3"
    assert finding.message =~ "MixedSuccess.parse/1"
    assert finding.message =~ "outside its declared contract"
    assert finding.message =~ ":ok (line 3)"
    assert finding.message =~ "{:ok, _} (line 4)"
  end

  test "finds raw values mixed with tagged results inside branches" do
    findings =
      smells("""
      defmodule RawOrTagged do
        @spec load(atom()) :: {:ok, atom()}
        def load(mode) do
          case mode do
            :raw -> %{status: :ready}
            :tagged -> {:ok, :ready}
          end
        end
      end
      """)

    assert [finding] = by_kind(findings, :return_shape_divergence)
    assert finding.message =~ "map (line 5)"
    assert finding.message =~ "{:ok, _} (line 6)"
  end

  test "finds inconsistent arity for the same tag" do
    findings =
      smells("""
      defmodule TagArity do
        @spec load(atom()) :: {:ok, atom()}
        def load(:plain), do: {:ok, :value}
        def load(:cached), do: {:ok, :value, :cached}
      end
      """)

    assert [_finding] = by_kind(findings, :return_shape_divergence)
  end

  test "keeps declared or unproven mixed contracts as evidence" do
    findings =
      smells("""
      defmodule IntentionalMixedReturns do
        @spec parse(atom()) :: :ok | {:ok, atom()}
        def parse(:empty), do: :ok
        def parse(value), do: {:ok, value}

        def undocumented(:empty), do: :ok
        def undocumented(value), do: {:ok, value}

        @type raw_result :: %{value: atom()}
        @spec open(atom()) :: {:ok, atom()} | raw_result()
        def open(:ok), do: {:ok, :value}
        def open(value), do: %{value: value}
      end
      """)

    assert by_kind(findings, :return_shape_divergence) == []
  end

  test "finds an unwrapped raw error beside tagged errors" do
    findings =
      smells("""
      defmodule AsymmetricErrors do
        def request(:ok), do: {:ok, :value}
        def request(:bad), do: {:error, :bad}
        def request(:offline), do: %RuntimeError{message: "offline"}
      end
      """)

    assert [_finding] = by_kind(findings, :return_shape_divergence)
  end

  test "finds tagged sentinel clauses mixed with raw successful values" do
    findings =
      smells("""
      defmodule SentinelShape do
        def parse(nil), do: {:ok, []}
        def parse(value), do: %{value: value}
      end
      """)

    assert [_finding] = by_kind(findings, :return_shape_divergence)
  end

  test "finds nested duplicate return tags independently" do
    findings =
      smells("""
      defmodule NestedTag do
        def load(value), do: {:ok, {:ok, value}}
      end
      """)

    assert [finding] = by_kind(findings, :nested_return_tag)
    assert finding.message =~ "wraps :ok inside the same return tag"
    assert by_kind(findings, :return_shape_divergence) == []
  end

  test "keeps conventional tagged and sentinel contracts clean" do
    findings =
      smells("""
      defmodule ConventionalReturns do
        def fetch(:ok), do: {:ok, :value}
        def fetch(:error), do: {:error, :missing}

        def lookup(:ok), do: {:ok, :value}
        def lookup(:error), do: :error

        def optional(:ok), do: {:ok, :value}
        def optional(:missing), do: nil
      end
      """)

    assert by_kind(findings, :return_shape_divergence) == []
  end

  test "keeps state-machine tuples and nested error reasons clean" do
    findings =
      smells("""
      defmodule StateMachineReturns do
        def transition(:ok, state), do: {:ok, state}
        def transition(:error, state), do: {{:error, :invalid}, state}

        def terminate(reason), do: {:error, {:error, reason}}
      end
      """)

    assert by_kind(findings, :return_shape_divergence) == []
    assert by_kind(findings, :nested_return_tag) == []
  end

  test "skips dynamic forwarding and @impl callbacks" do
    findings =
      smells("""
      defmodule DynamicAndCallback do
        def load(:known), do: {:ok, :value}
        def load(other), do: passthrough(other)

        @impl true
        def handle_call(:read, _from, state), do: {:reply, state, state}
        def handle_call(:stop, _from, state), do: {:stop, :normal, state}
      end
      """)

    assert by_kind(findings, :return_shape_divergence) == []
  end

  test "skips legacy OTP callbacks without explicit @impl annotations" do
    findings =
      smells("""
      defmodule LegacyCallback do
        @behaviour :gen_event
        def handle_call(:read, state), do: {:ok, state}
        def handle_call(:nested, state), do: {:ok, {:ok, state}}
      end
      """)

    assert by_kind(findings, :return_shape_divergence) == []
    assert by_kind(findings, :nested_return_tag) == []
  end

  test "ignores raising paths and with fallthrough" do
    findings =
      smells("""
      defmodule PartialReturns do
        def fetch!(:ok), do: {:ok, :value}
        def fetch!(:error), do: raise("missing")

        def decode(raw) do
          with {:ok, value} <- parse(raw) do
            {:ok, value}
          end
        end
      end
      """)

    assert by_kind(findings, :return_shape_divergence) == []
  end

  test "uses function-level else as the successful terminal shape" do
    findings =
      smells("""
      defmodule TransformedTryReturn do
        def cast(value) do
          String.to_integer(value)
        catch
          :error -> :error
        else
          integer -> {:ok, integer}
        end
      end
      """)

    assert by_kind(findings, :return_shape_divergence) == []
  end

  test "supports source suppression on the function contract" do
    findings =
      smells("""
      defmodule SuppressedReturns do
        @spec parse(atom()) :: {:ok, atom()}
        # reach:disable-next-line return_shape_divergence -- legacy callback contract
        def parse(:empty), do: :ok
        def parse(value), do: {:ok, value}
      end
      """)

    assert by_kind(findings, :return_shape_divergence) == []
  end

  defp by_kind(findings, kind), do: Enum.filter(findings, &(&1.kind == kind))

  defp smells(source) do
    path =
      Path.join(System.tmp_dir!(), "reach-return-shape-#{System.unique_integer([:positive])}.ex")

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)

    path
    |> List.wrap()
    |> Project.from_sources()
    |> Smells.run([])
  end
end
