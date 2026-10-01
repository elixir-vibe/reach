defmodule Reach.Smell.Checks.BehaviourCandidate do
  @moduledoc "Detects module groups sharing the same public callback set."

  @behaviour Reach.Smell.Check

  alias Reach.CloneAnalysis
  alias Reach.Config
  alias Reach.Smell.ContractCallbacks
  alias Reach.Smell.Finding
  alias Reach.Smell.Helpers

  @impl true
  def run(project), do: run(project, Config.normalize([]))

  def run(project, config) do
    config = Config.normalize(config)
    clone_evidence = CloneAnalysis.analyze(project, config)
    config = config.smells.behaviour_candidate

    project
    |> module_public_apis(config)
    |> Enum.group_by(& &1.signature)
    |> Enum.flat_map(&behaviour_candidate(&1, config, clone_evidence))
  end

  defp module_public_apis(project, config) do
    modules =
      for({_id, node} <- project.nodes, node.type == :module_def and node.source_span, do: node)

    contracts = ContractCallbacks.index(modules)
    functions = ContractCallbacks.functions(modules)
    Enum.flat_map(modules, &module_public_api(&1, config, contracts, functions))
  end

  defp module_public_api(module, config, contracts, functions) do
    contract = Map.fetch!(contracts, module.meta[:name])

    callbacks =
      module
      |> ContractCallbacks.module_functions()
      |> Enum.filter(&public_function?/1)
      |> Enum.reject(&ContractCallbacks.startup_facade?(&1, contract, functions))
      |> Enum.map(&function_signature/1)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.reject(&(ignored_callback?(&1) or MapSet.member?(contract.callbacks, &1)))

    if length(callbacks) >= config.min_callbacks do
      [
        %{
          module: inspect(module.meta[:name]),
          location: Helpers.location(module),
          signature: callbacks
        }
      ]
    else
      []
    end
  end

  defp public_function?(%{type: :function_def, meta: %{kind: kind}})
       when kind in [:def, :defmacro],
       do: true

  defp public_function?(_node), do: false

  defp function_signature(function), do: {function.meta[:name], function.meta[:arity]}

  defp ignored_callback?({:child_spec, 1}), do: true

  defp ignored_callback?({name, arity})
       when name in [:__struct__, :module_info] and arity in [0, 1],
       do: true

  defp ignored_callback?(_signature), do: false

  defp behaviour_candidate({callbacks, modules}, config, clone_evidence) do
    distinct_modules = Enum.uniq_by(modules, & &1.module)

    if length(distinct_modules) >= config.min_modules do
      sorted_modules = Enum.sort_by(distinct_modules, & &1.module)
      callback_names = Enum.map(callbacks, &format_callback/1)
      module_names = Enum.map(sorted_modules, & &1.module)
      matching_clones = matching_clone_evidence(clone_evidence, module_names, callbacks)

      [
        Finding.new(
          kind: :behaviour_candidate,
          message:
            "#{length(sorted_modules)} modules expose the same #{length(callbacks)} public callbacks; consider extracting a behaviour if these modules are interchangeable implementations",
          location: List.first(sorted_modules).location,
          evidence: Enum.map(sorted_modules, & &1.location) ++ clone_locations(matching_clones),
          modules: Enum.take(module_names, config.module_display_limit),
          callbacks: Enum.take(callback_names, config.callback_display_limit),
          confidence: if(matching_clones == [], do: :medium, else: :high),
          occurrences: length(sorted_modules)
        )
      ]
    else
      []
    end
  end

  defp matching_clone_evidence(clones, module_names, callbacks) do
    module_set = MapSet.new(module_names)
    callback_set = MapSet.new(callbacks)

    Enum.filter(clones, fn clone ->
      clone_modules =
        clone.fragments |> Enum.map(&module_name/1) |> Enum.reject(&is_nil/1) |> MapSet.new()

      clone_callbacks =
        clone.fragments |> Enum.map(&callback/1) |> Enum.reject(&is_nil/1) |> MapSet.new()

      MapSet.size(MapSet.intersection(module_set, clone_modules)) >= 2 and
        MapSet.size(MapSet.intersection(callback_set, clone_callbacks)) >= 1
    end)
  end

  defp clone_locations(clones) do
    clones
    |> Enum.flat_map(& &1.fragments)
    |> Enum.map(fn fragment -> "#{fragment.file}:#{fragment.line}" end)
    |> Enum.uniq()
  end

  defp module_name(%{module: nil}), do: nil
  defp module_name(%{module: module}), do: inspect(module)

  defp callback(%{function: nil}), do: nil
  defp callback(%{function: function, arity: arity}), do: {function, arity}

  defp format_callback({name, arity}), do: "#{name}/#{arity}"
end
