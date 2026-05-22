defmodule Reach.CLI.Render.Check.Smells do
  @moduledoc false

  alias Reach.CLI.Format
  alias Reach.Smell.Finding

  @evidence_display_limit 4

  def render(findings, "json", command) do
    Format.render(%{findings: findings}, command,
      format: "json",
      pretty: true
    )
  end

  def render(findings, "oneline", _command) do
    Enum.each(findings, fn finding ->
      IO.puts(
        "#{Format.location_text(finding.location)}: #{Format.yellow(to_string(finding.kind))}: #{finding.message}"
      )
    end)
  end

  def render(findings, _format, _command) do
    IO.puts(Format.header("Cross-Function Smell Detection"))

    if findings == [] do
      IO.puts("  " <> Format.empty("no issues"))
      IO.puts("")
    else
      grouped = Enum.group_by(findings, & &1.kind)

      render_group(Map.get(grouped, :redundant_traversal, []), "Redundant traversals")
      render_group(Map.get(grouped, :suboptimal, []), "Suboptimal patterns")
      render_group(Map.get(grouped, :redundant_computation, []), "Redundant computations")
      render_group(Map.get(grouped, :eager_pattern, []), "Eager where lazy suffices")
      render_group(Map.get(grouped, :string_building, []), "String building (use iolists)")
      render_group(Map.get(grouped, :config_phase, []), "Compile-time vs runtime config")
      render_group(structural_consistency(grouped), "Structural consistency")
      render_group(Map.get(grouped, :behaviour_candidate, []), "Behaviour candidates")
      render_group(Map.get(grouped, :dual_key_access, []), "Loose map contracts")
      rendered_kinds = rendered_kinds()

      render_group(Map.get(grouped, :fixed_shape_map, []), "Repeated map shapes")

      grouped
      |> Map.drop(rendered_kinds)
      |> Enum.sort_by(fn {kind, _findings} -> to_string(kind) end)
      |> Enum.each(fn {kind, findings} ->
        render_group(findings, Format.humanize(kind))
      end)

      IO.puts("  #{length(findings)} finding(s)\n")
    end
  end

  defp rendered_kinds do
    [
      :redundant_traversal,
      :suboptimal,
      :redundant_computation,
      :eager_pattern,
      :string_building,
      :config_phase,
      :return_contract_drift,
      :side_effect_order_drift,
      :map_contract_drift,
      :validation_drift,
      :behaviour_candidate,
      :dual_key_access,
      :fixed_shape_map
    ]
  end

  defp structural_consistency(grouped) do
    [:return_contract_drift, :side_effect_order_drift, :map_contract_drift, :validation_drift]
    |> Enum.flat_map(&Map.get(grouped, &1, []))
  end

  defp render_group([], _title), do: nil

  defp render_group(findings, title) do
    IO.puts(Format.section(title))
    Enum.each(findings, &render_finding/1)
  end

  defp render_finding(%Finding{kind: :behaviour_candidate} = finding) do
    IO.puts("  #{Format.location_text(finding.location)}")
    IO.puts("    #{Format.yellow(finding.message)}")

    if finding.modules do
      IO.puts("    modules=#{Enum.join(finding.modules, ", ")}")
    end

    if finding.callbacks do
      IO.puts("    callbacks=#{Enum.join(finding.callbacks, ", ")}")
    end
  end

  defp render_finding(%Finding{kind: :fixed_shape_map} = finding) do
    IO.puts("  #{Format.location_text(finding.location)}")

    summary =
      [
        Format.yellow("#{finding.occurrences}x"),
        Format.bright(Enum.join(finding.keys, ", ")),
        Format.faint("consider a struct or explicit contract")
      ]
      |> Enum.join("  ")

    IO.puts("    #{summary}")
    render_evidence(finding.evidence, finding.location)
  end

  defp render_finding(finding) do
    IO.puts("  #{Format.location_text(finding.location)}")
    IO.puts("    #{Format.yellow(finding.message)}")
  end

  defp render_evidence(evidence, primary_location) when is_list(evidence) do
    evidence
    |> Enum.reject(&(&1 == primary_location))
    |> Enum.take(@evidence_display_limit)
    |> case do
      [] ->
        :ok

      locations ->
        IO.puts("    #{Format.faint("also:")}")
        Enum.each(locations, &IO.puts("      #{Format.location_text(&1)}"))
    end
  end

  defp render_evidence(_evidence, _primary_location), do: :ok
end
