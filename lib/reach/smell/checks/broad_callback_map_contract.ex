defmodule Reach.Smell.Checks.BroadCallbackMapContract do
  @moduledoc "Detects broad map callback parameters with stable implementation shapes."

  @behaviour Reach.Smell.Check

  alias Reach.Evidence.MapContract
  alias Reach.MacroFact
  alias Reach.Smell.{Finding, Helpers}

  @minimum_keys 3
  @strong_single_keys 5

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
    parameter_index = parameter_index(project)

    project
    |> MapContract.collect_key_accesses()
    |> Enum.filter(&match?({:literal, _key}, &1.logical_key))
    |> Enum.flat_map(fn access ->
      indexes =
        access.map_origins
        |> Enum.map(&Map.get(parameter_index, {access.function, &1}))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      Enum.map(indexes, fn index ->
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

  defp parameter_index(project) do
    project.nodes
    |> Map.values()
    |> Enum.filter(&(&1.type == :function_def))
    |> Enum.reduce(%{}, &index_function_parameters/2)
  end

  defp index_function_parameters(function, index) do
    function_id = {function.meta[:module], function.meta[:name], function.meta[:arity]}

    function.children
    |> Enum.filter(&(&1.type == :clause))
    |> Enum.reduce(index, fn clause, index ->
      clause.children
      |> Enum.take(function.meta[:arity])
      |> Stream.with_index()
      |> Enum.reduce(index, fn {parameter, parameter_index}, index ->
        parameter
        |> descendants()
        |> Enum.reduce(index, &Map.put(&2, {function_id, &1.id}, parameter_index))
      end)
    end)
  end

  defp descendants(node), do: [node | Enum.flat_map(node.children, &descendants/1)]

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

    cond do
      length(shapes) >= 2 and length(common_keys) >= @minimum_keys ->
        %{shapes: shapes, keys: common_keys}

      shape = Enum.find(shapes, &(length(&1.keys) >= @strong_single_keys)) ->
        %{shapes: [shape], keys: shape.keys}

      true ->
        nil
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
