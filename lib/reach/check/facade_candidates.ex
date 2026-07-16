defmodule Reach.Check.FacadeCandidates do
  @moduledoc "Builds advisory candidates for modules dominated by public pass-through functions."

  alias Reach.Check.{Architecture, Candidate}

  @spec build([Reach.Evidence.Facade.Module.t()], Reach.Config.t()) :: [Candidate.t()]
  def build(evidence, config) do
    thresholds = config.candidates.thresholds

    evidence
    |> Enum.filter(&candidate?(&1, thresholds))
    |> Enum.reject(&intentional_boundary?(&1, config))
    |> Enum.sort_by(&{-&1.forwarder_ratio, -&1.forwarder_count, &1.module})
    |> Enum.take(config.candidates.limits.per_kind)
    |> Enum.with_index(1)
    |> Enum.map(fn {facade, index} -> candidate(facade, index, config) end)
  end

  defp candidate?(facade, thresholds) do
    facade.public_function_count >= thresholds.facade_min_functions and
      facade.forwarder_ratio >= thresholds.facade_ratio and
      facade.boundary_markers in [nil, []] and
      facade.target_modules != [] and
      length(facade.target_modules) <= thresholds.facade_max_targets
  end

  defp intentional_boundary?(facade, config) do
    Enum.any?(config.boundaries.public, fn pattern ->
      Architecture.glob_match?(facade.module, to_string(pattern))
    end)
  end

  defp candidate(facade, index, config) do
    Candidate.new(
      id: "R8-#{String.pad_leading(to_string(index), 3, "0")}",
      kind: :review_facade,
      target: target(facade),
      file: facade.file,
      line: facade.line,
      benefit: :medium,
      risk: :low,
      confidence: confidence(facade),
      actionability: :needs_boundary_intent_review,
      evidence: [
        "#{facade.forwarder_count}/#{facade.public_function_count}_public_functions_forward",
        "targets=#{Enum.join(facade.target_modules, ",")}",
        "documented=#{facade.documented == true}"
      ],
      representative_calls:
        representative_calls(facade, config.candidates.limits.representative_calls),
      proof: [
        "Confirm whether the module is an intentional stable public boundary before changing it.",
        "Check callers for API ownership, authorization, telemetry, or compatibility semantics.",
        "Remove the layer only when callers can depend on the target module without weakening architecture."
      ],
      suggestion:
        "Declare this module in boundaries[:public] when it is intentional; otherwise call the target directly or move real boundary behavior here."
    )
  end

  defp target(facade) do
    "#{facade.module} forwards #{facade.forwarder_count}/#{facade.public_function_count} public functions to #{Enum.join(facade.target_modules, ", ")}"
  end

  defp confidence(%{forwarder_ratio: 1.0, target_modules: [_target], documented: false}),
    do: :high

  defp confidence(_facade), do: :medium

  defp representative_calls(facade, limit) do
    facade.forwarders
    |> Enum.take(limit)
    |> Enum.map(fn forwarder ->
      %{
        caller_module: facade.module,
        callee_module: forwarder.target_module,
        file: forwarder.file,
        line: forwarder.line,
        call: "#{forwarder.target_module}.#{forwarder.target_function}/#{forwarder.target_arity}"
      }
    end)
  end
end
