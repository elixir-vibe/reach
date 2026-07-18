defmodule Reach.Smell.Checks.MapKeyNormalizationTest do
  use ExUnit.Case, async: true

  alias Reach.Check.Smells
  alias Reach.Project

  test "flags collision-prone atom-to-string map normalization" do
    findings =
      """
      defmodule Normalizer do
        def stringify(map) do
          Map.new(map, fn {key, value} ->
            normalized_key = if is_atom(key), do: Atom.to_string(key), else: key
            {normalized_key, value}
          end)
        end
      end
      """
      |> project_from_string()
      |> Smells.run()

    assert Enum.any?(findings, &(&1.kind == :key_normalization_collision))
  end

  test "flags collision-prone normalization expressed as mapper clauses" do
    findings =
      """
      defmodule Normalizer do
        def stringify(map) do
          Map.new(map, fn
            {key, value} when is_atom(key) -> {Atom.to_string(key), value}
            {key, value} -> {key, value}
          end)
        end
      end
      """
      |> project_from_string()
      |> Smells.run()

    assert Enum.any?(findings, &(&1.kind == :key_normalization_collision))
  end

  test "flags collision-prone string-to-atom map normalization" do
    findings =
      """
      defmodule Normalizer do
        def atomize(map) do
          Map.new(map, fn {key, value} ->
            normalized_key = if is_binary(key), do: String.to_existing_atom(key), else: key
            {normalized_key, value}
          end)
        end
      end
      """
      |> project_from_string()
      |> Smells.run()

    assert Enum.any?(findings, &(&1.kind == :key_normalization_collision))
  end

  test "coalesces alternative conversion branches in one map normalization" do
    findings =
      """
      defmodule Normalizer do
        def atomize(map) do
          Map.new(map, fn
            {key, value} when is_binary(key) ->
              try do
                {String.to_existing_atom(key), value}
              rescue
                ArgumentError -> {String.to_atom(key), value}
              end

            {key, value} ->
              {key, value}
          end)
        end
      end
      """
      |> project_from_string()
      |> Smells.run()

    collisions = Enum.filter(findings, &(&1.kind == :key_normalization_collision))

    assert length(collisions) == 1
    assert length(hd(collisions).evidence) == 2
  end

  test "flags opposite normalizers on one value-flow path" do
    findings =
      """
      defmodule Normalizer do
        def cycle(map), do: atomize(stringify(map))

        def stringify(map) do
          Map.new(map, fn {key, value} ->
            normalized_key = if is_atom(key), do: Atom.to_string(key), else: key
            {normalized_key, value}
          end)
        end

        def atomize(map) do
          Map.new(map, fn {key, value} ->
            normalized_key = if is_binary(key), do: String.to_existing_atom(key), else: key
            {normalized_key, value}
          end)
        end
      end
      """
      |> project_from_string()
      |> Smells.run()

    assert Enum.any?(findings, &(&1.kind == :key_representation_churn))
  end

  test "does not join opposite normalizers on unrelated values" do
    findings =
      """
      defmodule Normalizer do
        def separate(left, right), do: {stringify(left), atomize(right)}

        def stringify(map) do
          Map.new(map, fn {key, value} ->
            normalized_key = if is_atom(key), do: Atom.to_string(key), else: key
            {normalized_key, value}
          end)
        end

        def atomize(map) do
          Map.new(map, fn {key, value} ->
            normalized_key = if is_binary(key), do: String.to_existing_atom(key), else: key
            {normalized_key, value}
          end)
        end
      end
      """
      |> project_from_string()
      |> Smells.run()

    refute Enum.any?(findings, &(&1.kind == :key_representation_churn))
  end

  test "does not flag a total conversion without a preserved target-key branch" do
    findings =
      """
      defmodule Normalizer do
        def stringify(map) do
          Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
        end
      end
      """
      |> project_from_string()
      |> Smells.run()

    refute Enum.any?(findings, &(&1.kind == :key_normalization_collision))
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
