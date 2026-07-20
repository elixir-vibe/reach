defmodule Reach.Smell.Checks.DefaultDriftTest do
  use ExUnit.Case, async: true

  alias Reach.Check.Smells
  alias Reach.Project

  test "flags conflicting defaults for atom and string forms of one key" do
    findings =
      project_from_string("""
      defmodule Options do
        def timeout(options) do
          fast = Map.get(options, :timeout, 1_000)
          slow = Map.get(options, "timeout", 5_000)
          {fast, slow}
        end
      end
      """)
      |> Smells.run()

    assert [%{kind: :default_drift, keys: ["timeout"], location: location, evidence: evidence}] =
             Enum.filter(findings, &(&1.kind == :default_drift))

    assert String.ends_with?(location, ":3")
    assert Enum.map(evidence, &(&1 |> String.split(":") |> List.last())) == ["3", "4"]
  end

  test "orders numerically equal defaults by exact term representation" do
    messages =
      for {first, second} <- [{"0", "0.0"}, {"0.0", "0"}] do
        findings =
          project_from_string("""
          defmodule Options do
            def value(options) do
              first = Map.get(options, :value, #{first})
              second = Map.get(options, :value, #{second})
              {first, second}
            end
          end
          """)
          |> Smells.run()

        [finding] = Enum.filter(findings, &(&1.kind == :default_drift))
        finding.message
      end

    assert [message, message] = messages
  end

  test "flags conflicting defaults for a dynamic logical key" do
    findings =
      project_from_string("""
      defmodule Options do
        def value(options, key) do
          first = Map.get(options, key, false)
          second = Map.get(options, Atom.to_string(key), true)
          {first, second}
        end
      end
      """)
      |> Smells.run()

    assert Enum.any?(findings, &(&1.kind == :default_drift))
  end

  test "follows a shared map origin across local calls" do
    findings =
      project_from_string("""
      defmodule Options do
        def both(options), do: {short(options), long(options)}
        def short(options), do: Map.get(options, :timeout, 1_000)
        def long(options), do: Map.get(options, :timeout, 5_000)
      end
      """)
      |> Smells.run()

    assert Enum.any?(findings, &(&1.kind == :default_drift))
  end

  test "does not flag defaults selected by mutually exclusive case clauses" do
    findings =
      project_from_string("""
      defmodule Options do
        def shutdown(child) do
          type = Map.get(child, :type, :worker)

          case type do
            :worker -> Map.get(child, :shutdown, 5_000)
            :supervisor -> Map.get(child, :shutdown, :infinity)
          end
        end
      end
      """)
      |> Smells.run()

    refute Enum.any?(findings, &(&1.kind == :default_drift))
  end

  test "does not join unrelated map origins" do
    findings =
      project_from_string("""
      defmodule Options do
        def timeout(left, right) do
          {Map.get(left, :timeout, 1_000), Map.get(right, :timeout, 5_000)}
        end
      end
      """)
      |> Smells.run()

    refute Enum.any?(findings, &(&1.kind == :default_drift))
  end

  test "does not join the same dynamic key across different derived maps" do
    findings =
      project_from_string("""
      defmodule State do
        def limits(state, key) do
          {Map.get(state.counts, key, 0), Map.get(state.limits, key, 1)}
        end
      end
      """)
      |> Smells.run()

    refute Enum.any?(findings, &(&1.kind == :default_drift))
  end

  test "does not join distinct computed keys with shared flow origins" do
    findings =
      project_from_string("""
      defmodule Totals do
        def read(values, key) do
          count_key = key
          amount_key = key
          {Map.get(values, count_key, 0), Map.get(values, amount_key, 0.0)}
        end
      end
      """)
      |> Smells.run()

    refute Enum.any?(findings, &(&1.kind == :default_drift))
  end

  test "does not treat one atom-string fallback chain as default drift" do
    findings =
      project_from_string("""
      defmodule Payload do
        def name(payload) do
          Map.get(payload, :name, nil) || Map.get(payload, "name", "")
        end
      end
      """)
      |> Smells.run()

    refute Enum.any?(findings, &(&1.kind == :default_drift))
  end

  test "does not join implementation-specific defaults across modules" do
    findings =
      project_from_string("""
      defmodule Chart do
        def title(opts), do: Map.get(opts, :title, "Chart")
      end

      defmodule Treemap do
        def title(opts), do: Map.get(opts, :title, "Treemap")
      end
      """)
      |> Smells.run()

    refute Enum.any?(findings, &(&1.kind == :default_drift))
  end

  test "does not flag same-line reads serving distinct expression roles" do
    findings =
      project_from_string("""
      defmodule Style do
        def height(assigns) do
          %{"max-height: \#{Map.get(assigns, :height, "0")}" => Map.get(assigns, :height, nil) != nil}
        end
      end
      """)
      |> Smells.run()

    refute Enum.any?(findings, &(&1.kind == :default_drift))
  end

  test "does not flag repeated use of one default" do
    findings =
      project_from_string("""
      defmodule Options do
        def timeout(options) do
          {Map.get(options, :timeout, 1_000), Map.get(options, "timeout", 1_000)}
        end
      end
      """)
      |> Smells.run()

    refute Enum.any?(findings, &(&1.kind == :default_drift))
  end

  defp project_from_string(source) do
    graph = Reach.string_to_graph!(source)

    %Project{
      modules: %{},
      graph: Reach.to_graph(graph),
      nodes: Map.new(Reach.nodes(graph), &{&1.id, &1}),
      call_graph: graph.call_graph,
      plugins: []
    }
  end
end
