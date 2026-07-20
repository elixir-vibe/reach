defmodule Reach.Smell.Checks.BroadCallbackMapContract do
  @moduledoc "Detects broad map callback parameters with stable implementation shapes."

  @behaviour Reach.Smell.Check

  alias Reach.Evidence.MapContract
  alias Reach.MacroFact
  alias Reach.Smell.{Finding, Helpers}

  @minimum_keys 3

  @impl true
  def kinds, do: [:broad_callback_map_contract]

  @impl true
  def run(project) do
    facts = MacroFact.collect_project(project)
    shapes = implementation_shapes(project)

    facts
    |> callback_facts()
    |> Enum.flat_map(&callback_findings(&1, facts, shapes))
  end

  defp callback_facts(facts) do
    Enum.filter(facts, fn
      %MacroFact{
        kind: :typespec_declaration,
        data: %{declaration_kind: :callback, broad_map_parameters: indexes}
      } ->
        indexes != []

      _fact ->
        false
    end)
  end

  defp callback_findings(callback, facts, shapes) do
    implementations = implementation_modules(facts, callback.owner_module)

    Enum.flat_map(callback.data.broad_map_parameters, fn parameter_index ->
      matching =
        shapes
        |> Enum.filter(fn shape ->
          {module, name, arity} = shape.function

          module in implementations and name == callback.name and arity == callback.arity and
            shape.parameter_index == parameter_index
        end)
        |> merge_implementation_shapes()
        |> Enum.filter(&consistent_representation?/1)

      case promotable_shape(matching) do
        nil -> []
        shape -> [finding(callback, parameter_index, shape)]
      end
    end)
  end

  defp implementation_modules(facts, behaviour) do
    facts
    |> Enum.flat_map(fn
      %MacroFact{kind: :behaviour_declaration, owner_module: module, target: ^behaviour} ->
        [module]

      %MacroFact{name: :use, owner_module: module, target: ^behaviour} ->
        [module]

      _fact ->
        []
    end)
    |> Enum.uniq()
  end

  defp implementation_shapes(project) do
    parameter_index = MapContract.parameter_origin_index(project)
    nested_bindings = MapContract.nested_parameter_bindings(project)

    project
    |> MapContract.collect_key_accesses()
    |> Enum.filter(&match?({:literal, _key}, &1.logical_key))
    |> Enum.flat_map(fn access ->
      indexes =
        access.map_origins
        |> Enum.map(&Map.get(parameter_index, {access.function, &1}))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      indexes
      |> Enum.reject(&MapContract.nested_parameter_access?(access, &1, nested_bindings))
      |> Enum.map(fn index ->
        %{
          function: access.function,
          parameter_index: index,
          keys: [access.key_label],
          accesses: [access],
          representations: [access.representation]
        }
      end)
    end)
  end

  defp merge_implementation_shapes(shapes) do
    shapes
    |> Enum.group_by(fn shape -> elem(shape.function, 0) end)
    |> Enum.map(fn {module, module_shapes} ->
      %{
        module: module,
        keys: module_shapes |> Enum.flat_map(& &1.keys) |> Enum.uniq() |> Enum.sort(),
        accesses: Enum.flat_map(module_shapes, & &1.accesses),
        representations: module_shapes |> Enum.flat_map(& &1.representations) |> Enum.uniq()
      }
    end)
  end

  defp consistent_representation?(shape), do: length(shape.representations) == 1

  defp promotable_shape(shapes) do
    common_keys = common_keys(shapes)

    if length(shapes) >= 2 and length(common_keys) >= @minimum_keys do
      %{shapes: shapes, keys: common_keys}
    end
  end

  defp common_keys([]), do: []

  defp common_keys([first | rest]) do
    rest
    |> Enum.reduce(MapSet.new(first.keys), fn shape, common ->
      MapSet.intersection(common, MapSet.new(shape.keys))
    end)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp finding(callback, parameter_index, shape) do
    modules = Enum.map(shape.shapes, & &1.module)
    accesses = Enum.flat_map(shape.shapes, & &1.accesses)

    Finding.new(
      kind: :broad_callback_map_contract,
      message:
        "#{format_target(callback.target)} parameter #{parameter_index + 1} declares map() but implementations consistently read fixed keys #{Enum.map_join(shape.keys, ", ", &inspect/1)}",
      location: Helpers.source_location(callback.source),
      evidence: Enum.map(accesses, &Helpers.location(&1.node)) |> Enum.uniq(),
      keys: shape.keys,
      modules: modules,
      confidence: :high
    )
  end

  defp format_target({module, name, arity}), do: "#{inspect(module)}.#{name}/#{arity}"
end
