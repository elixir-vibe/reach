defmodule Reach.Smell.Checks.BroadMapContract do
  @moduledoc "Detects broad map specs where implementation access reveals a stable shape."

  @behaviour Reach.Smell.Check

  alias Reach.Evidence.MapContract
  alias Reach.MacroFact
  alias Reach.Smell.{Finding, Helpers}

  @minimum_keys 3

  @impl true
  def kinds, do: [:broad_map_contract]

  @impl true
  def run(project) do
    observed_shapes = observed_shapes(project)

    project
    |> MacroFact.collect_project()
    |> Enum.filter(&broad_function_spec?/1)
    |> Enum.flat_map(&finding_for_spec(&1, observed_shapes))
  end

  defp observed_shapes(project) do
    project
    |> MapContract.collect_key_accesses()
    |> Enum.filter(&match?({:literal, _key}, &1.logical_key))
    |> Enum.group_by(&{&1.function, &1.map_origins})
    |> Enum.flat_map(fn {{function, _origins}, accesses} ->
      keys = accesses |> Enum.map(& &1.key_label) |> Enum.uniq() |> Enum.sort()

      if length(keys) >= @minimum_keys do
        [{function, keys, accesses}]
      else
        []
      end
    end)
  end

  defp broad_function_spec?(%MacroFact{
         data: %{declaration_kind: :spec, broad_map_parameters: [_index]}
       }),
       do: true

  defp broad_function_spec?(_fact), do: false

  defp finding_for_spec(spec, observed_shapes) do
    observed_shapes
    |> Enum.filter(fn {function, _keys, _accesses} -> function == spec.target end)
    |> Enum.map(fn {_function, keys, accesses} ->
      Finding.new(
        kind: :broad_map_contract,
        message:
          "#{format_target(spec.target)} declares map() but consistently reads fixed keys #{Enum.map_join(keys, ", ", &inspect/1)}; declare the shape explicitly",
        location: Helpers.source_location(spec.source),
        evidence: Enum.map(accesses, &Helpers.location(&1.node)) |> Enum.uniq(),
        keys: keys,
        confidence: :high
      )
    end)
  end

  defp format_target({module, name, arity}), do: "#{inspect(module)}.#{name}/#{arity}"
end
