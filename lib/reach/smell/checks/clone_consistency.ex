defmodule Reach.Smell.Checks.CloneConsistency do
  @moduledoc "Detects structural drift across clone families."

  @behaviour Reach.Smell.Check

  alias Reach.Config
  alias Reach.Evidence.CloneAnalysis
  alias Reach.Smell.Finding

  @impl true
  def run(project), do: run(project, Config.normalize([]))

  def run(project, config) do
    config = Config.normalize(config)

    project
    |> CloneAnalysis.analyze(config)
    |> Enum.flat_map(&findings/1)
  end

  defp findings(clone) do
    fragments = meaningful_fragments(clone.fragments)

    [
      &return_contract_drift/1,
      &side_effect_order_drift/1,
      &map_contract_drift/1,
      &validation_drift/1
    ]
    |> Enum.flat_map(& &1.(fragments))
  end

  defp meaningful_fragments(fragments) do
    fragments
    |> Enum.filter(&(&1.module && &1.function && &1.file && &1.line))
    |> Enum.uniq_by(&{&1.module, &1.function, &1.arity, &1.file, &1.line})
  end

  defp return_contract_drift(fragments) do
    fragments
    |> singleton_drift_groups(&normalize_return_shapes(&1.return_shapes))
    |> Enum.map(fn {outlier, majority} ->
      Finding.new(
        kind: :return_contract_drift,
        message:
          "#{function_name(outlier)} returns #{format_shapes(normalize_return_shapes(outlier.return_shapes))} while similar functions return #{format_shapes(normalize_return_shapes(majority.return_shapes))}; align the contract or split the abstraction",
        location: location(outlier),
        evidence: evidence([outlier, majority]),
        confidence: :high
      )
    end)
  end

  defp side_effect_order_drift(fragments) do
    fragments
    |> Enum.reject(&(length(&1.effect_sequence) < 2))
    |> singleton_drift_groups(& &1.effect_sequence)
    |> Enum.map(fn {outlier, majority} ->
      Finding.new(
        kind: :side_effect_order_drift,
        message:
          "#{function_name(outlier)} has a different side-effect order than similar functions; verify observable operation ordering before refactoring",
        location: location(outlier),
        evidence: evidence([outlier, majority]),
        confidence: :high
      )
    end)
  end

  defp map_contract_drift(fragments) do
    accesses =
      for fragment <- fragments,
          {variable, key, key_type} <- fragment.map_accesses do
        {{variable, key}, key_type, fragment}
      end

    accesses
    |> Enum.group_by(fn {field, _key_type, _fragment} -> field end)
    |> Enum.flat_map(&map_contract_finding/1)
  end

  defp map_contract_finding({{variable, key}, entries}) do
    key_types = entries |> Enum.map(fn {_field, type, _fragment} -> type end) |> MapSet.new()

    if MapSet.size(key_types) > 1 do
      locations =
        entries
        |> Enum.map(fn {_field, _type, fragment} -> location(fragment) end)
        |> Enum.uniq()

      [
        Finding.new(
          kind: :map_contract_drift,
          message:
            "similar functions access #{variable}.#{key} with mixed atom/string keys; normalize boundary data once or introduce a struct/contract",
          location: List.first(locations),
          evidence: locations,
          confidence: :high
        )
      ]
    else
      []
    end
  end

  defp validation_drift(fragments) do
    write_fragments = Enum.filter(fragments, &(:write in &1.effects))

    if length(write_fragments) >= 2 do
      with_validation = Enum.filter(write_fragments, &(&1.validation_calls != []))
      without_validation = write_fragments -- with_validation

      case {with_validation, without_validation} do
        {[_ | _], [outlier | _]} ->
          [
            Finding.new(
              kind: :validation_drift,
              message:
                "#{function_name(outlier)} performs write effects without validation calls seen in similar functions; check boundary validation before persistence",
              location: location(outlier),
              evidence: evidence([outlier | with_validation]),
              confidence: :high
            )
          ]

        _ ->
          []
      end
    else
      []
    end
  end

  defp singleton_drift_groups(fragments, key_fun) do
    fragments
    |> Enum.group_by(key_fun)
    |> Map.values()
    |> case do
      [] ->
        []

      [_one] ->
        []

      groups ->
        sorted = Enum.sort_by(groups, &length/1, :desc)
        majority = sorted |> hd() |> hd()

        sorted
        |> tl()
        |> Enum.filter(&(length(&1) == 1))
        |> Enum.map(fn [outlier] -> {outlier, majority} end)
    end
  end

  defp normalize_return_shapes([]), do: [:raw]
  defp normalize_return_shapes(shapes), do: shapes

  defp function_name(fragment),
    do: "#{inspect(fragment.module)}.#{fragment.function}/#{fragment.arity}"

  defp location(fragment), do: "#{fragment.file}:#{fragment.line}"

  defp evidence(fragments) do
    fragments
    |> Enum.map(&location/1)
    |> Enum.uniq()
  end

  defp format_shapes(shapes) do
    Enum.map_join(shapes, " | ", &format_shape/1)
  end

  defp format_shape({:struct, module}), do: "%#{inspect(module)}{}"
  defp format_shape(shape), do: Atom.to_string(shape)
end
