defmodule Reach.Smell.Checks.BroadMapContract do
  @moduledoc "Detects broad map specs contradicted by strict, stable parameter access."

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
    |> Enum.flat_map(&findings_for_spec(&1, observed_shapes))
  end

  defp observed_shapes(project) do
    parameter_index = MapContract.parameter_origin_index(project)
    nested_bindings = MapContract.nested_parameter_bindings(project)

    project
    |> MapContract.collect_key_accesses()
    |> Enum.filter(&match?({:literal, _key}, &1.logical_key))
    |> Enum.flat_map(&parameter_access(&1, parameter_index, nested_bindings))
    |> Enum.group_by(&{&1.function, &1.parameter_index, &1.map_origins})
    |> Enum.flat_map(fn {{function, parameter_index, _origins}, parameter_accesses} ->
      accesses = Enum.map(parameter_accesses, & &1.access)
      keys = accesses |> Enum.map(& &1.key_label) |> Enum.uniq() |> Enum.sort()

      if length(keys) >= @minimum_keys do
        [
          %{
            function: function,
            parameter_index: parameter_index,
            keys: keys,
            accesses: accesses,
            strict?: Enum.any?(accesses, &(&1.operation == :fetch!))
          }
        ]
      else
        []
      end
    end)
  end

  defp parameter_access(access, parameter_index, nested_bindings) do
    indexes =
      access.map_origins
      |> Enum.map(&Map.get(parameter_index, {access.function, &1}))

    case Enum.uniq(indexes) do
      [index] when is_integer(index) ->
        if MapContract.nested_parameter_access?(access, index, nested_bindings) do
          []
        else
          [
            %{
              function: access.function,
              parameter_index: index,
              map_origins: access.map_origins,
              access: access
            }
          ]
        end

      _mixed_or_derived ->
        []
    end
  end

  defp broad_function_spec?(%MacroFact{
         data: %{declaration_kind: :spec, broad_map_parameters: indexes}
       }),
       do: indexes != []

  defp broad_function_spec?(_fact), do: false

  defp findings_for_spec(spec, observed_shapes) do
    Enum.flat_map(spec.data.broad_map_parameters, fn parameter_index ->
      case matching_shapes(observed_shapes, spec.target, parameter_index) do
        [%{strict?: true} = shape] -> [finding(spec, shape)]
        _open_or_multiple_shapes -> []
      end
    end)
  end

  defp matching_shapes(shapes, function, parameter_index) do
    Enum.filter(shapes, &(&1.function == function and &1.parameter_index == parameter_index))
  end

  defp finding(spec, shape) do
    Finding.new(
      kind: :broad_map_contract,
      message:
        "#{format_target(spec.target)} parameter #{shape.parameter_index + 1} declares map() but uses strict access within the fixed key set #{Enum.map_join(shape.keys, ", ", &inspect/1)}; declare the shape explicitly",
      location: Helpers.source_location(spec.source),
      evidence: Enum.map(shape.accesses, &Helpers.location(&1.node)) |> Enum.uniq(),
      keys: shape.keys,
      confidence: :high
    )
  end

  defp format_target({module, name, arity}), do: "#{inspect(module)}.#{name}/#{arity}"
end
