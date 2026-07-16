defmodule Reach.Smell.Checks.DualKeyFallbackTest do
  use ExUnit.Case, async: true

  alias Reach.Check.Smells
  alias Reach.Project

  test "flags dynamic atom/string fallback helpers and false collapse" do
    findings =
      """
      defmodule LooseContract do
        def get(map, key) do
          Map.get(map, key) || Map.get(map, Atom.to_string(key)) || true
        end
      end
      """
      |> project_from_string()
      |> Smells.run()

    assert Enum.any?(findings, &(&1.kind == :dual_key_fallback))
    assert Enum.any?(findings, &(&1.kind == :false_collapsing_lookup))
  end

  test "flags false collapse for boolean-shaped map keys" do
    findings =
      """
      defmodule FeatureFlags do
        def enabled(map, default) do
          Map.get(map, :enabled) || Map.get(map, "enabled") || default
        end
      end
      """
      |> project_from_string()
      |> Smells.run()

    assert Enum.any?(findings, &(&1.kind == :false_collapsing_lookup))
  end

  test "flags a two-access literal fallback without lowering the density rule" do
    findings =
      """
      defmodule LooseContract do
        def get(map) do
          Map.get(map, :enabled) || Map.get(map, "enabled")
        end
      end
      """
      |> project_from_string()
      |> Smells.run()

    assert Enum.any?(findings, &(&1.kind == :dual_key_fallback))
    refute Enum.any?(findings, &(&1.kind == :dual_key_access))
    refute Enum.any?(findings, &(&1.kind == :false_collapsing_lookup))
  end

  test "reports false collapse once for a fallback with multiple logical keys" do
    findings =
      """
      defmodule LooseContract do
        def get(map) do
          Map.get(map, :id) || Map.get(map, "id") ||
            Map.get(map, :call_id) || Map.get(map, "call_id") || true
        end
      end
      """
      |> project_from_string()
      |> Smells.run()

    assert Enum.count(findings, &(&1.kind == :dual_key_fallback)) == 2
    assert Enum.count(findings, &(&1.kind == :false_collapsing_lookup)) == 1
  end

  test "requires boolean-domain evidence for false collapse" do
    findings =
      """
      defmodule RequiredField do
        def get(map, key, default) do
          Map.get(map, key) || Map.get(map, Atom.to_string(key)) || default
        end
      end
      """
      |> project_from_string()
      |> Smells.run()

    assert Enum.any?(findings, &(&1.kind == :dual_key_fallback))
    refute Enum.any?(findings, &(&1.kind == :false_collapsing_lookup))
  end

  test "recognizes nested defaults without reporting false collapse" do
    findings =
      """
      defmodule LooseContract do
        def get(map, default) do
          Map.get(map, :enabled, Map.get(map, "enabled", default))
        end
      end
      """
      |> project_from_string()
      |> Smells.run()

    assert Enum.any?(findings, &(&1.kind == :dual_key_fallback))
    refute Enum.any?(findings, &(&1.kind == :false_collapsing_lookup))
  end

  test "does not flag a fallback nested inside a broader operation" do
    findings =
      """
      defmodule RequestBuilder do
        def body(map) do
          encode(%{enabled: Map.get(map, :enabled) || Map.get(map, "enabled")})
        end
      end
      """
      |> project_from_string()
      |> Smells.run()

    refute Enum.any?(findings, &(&1.kind in [:dual_key_fallback, :false_collapsing_lookup]))
  end

  test "does not join keys or maps with different value origins" do
    findings =
      """
      defmodule SeparateContracts do
        def get(left, right, atom_key, string_key) do
          Map.get(left, atom_key) || Map.get(right, Atom.to_string(string_key))
        end
      end
      """
      |> project_from_string()
      |> Smells.run()

    refute Enum.any?(findings, &(&1.kind in [:dual_key_fallback, :false_collapsing_lookup]))
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
