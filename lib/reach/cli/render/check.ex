defmodule Reach.CLI.Render.Check do
  @moduledoc false

  alias Reach.CLI.Format
  alias Reach.CLI.Requirements

  @text_limit 30

  def render_no_default do
    IO.puts("No default Reach checks configured.")
    IO.puts("Use --arch, --changed, --dead-code, --smells, or --candidates.")
  end

  def render_result(result, "json", _text_fun) do
    Requirements.json!()
    IO.puts(Jason.encode!(json_envelope(result), pretty: true))
  end

  def render_result(result, _format, text_fun), do: text_fun.(result)

  def render_candidates_text(%{candidates: []}) do
    IO.puts(Format.header("Refactoring Candidates"))
    IO.puts("  " <> Format.empty("no refactoring candidates"))
  end

  def render_candidates_text(%{candidates: candidates, note: note}) do
    IO.puts(Format.header("Refactoring Candidates (#{length(candidates)})"))
    IO.puts(Format.faint(note))
    IO.puts("")

    Enum.each(candidates, fn candidate ->
      IO.puts(
        "  #{Format.bright(candidate.id)} #{Format.yellow(Format.humanize(candidate.kind))}: #{candidate.target}"
      )

      IO.puts(
        "    benefit=#{candidate.benefit} risk=#{Format.risk(candidate.risk)} confidence=#{Format.risk(Map.get(candidate, :confidence, :unknown))}"
      )

      if Map.get(candidate, :file) do
        IO.puts("    #{Format.loc(candidate.file, candidate.line)}")
      end

      IO.puts("    evidence=#{Format.humanized_join(candidate.evidence)}")

      render_representative_calls(candidate)

      IO.puts("    suggestion=#{candidate.suggestion}")
      IO.puts("")
    end)
  end

  def render_arch_text(%{violations: []}) do
    IO.puts(Format.header("Architecture Policy"))
    IO.puts("  #{Format.green("OK")}")
  end

  def render_arch_text(%{violations: violations}) do
    IO.puts(Format.header("Architecture Policy"))
    IO.puts("  #{Format.red("#{length(violations)} violation(s)")}")

    Enum.each(violations, fn
      %{type: type} = violation when type in [:config_error, "config_error"] ->
        IO.puts("  config #{violation.key}: #{violation.message}")

      %{type: type} = violation when type in [:forbidden_module, "forbidden_module"] ->
        IO.puts(
          "  #{Format.loc(violation.file, violation.line)} #{violation.module} (#{violation.rule})"
        )

      %{type: type} = violation when type in [:forbidden_file, "forbidden_file"] ->
        IO.puts("  #{Format.path(violation.file)} (#{violation.rule})")

      %{type: type} = violation when type in [:missing_layer, "missing_layer"] ->
        IO.puts("  missing layer: #{violation.module} (#{violation.rule})")

      %{type: type} = violation when type in [:multiple_layers, "multiple_layers"] ->
        IO.puts("  matched multiple layers: #{violation.module}")

        violation.matched_layers
        |> List.wrap()
        |> Enum.each(&IO.puts("    - #{&1}"))

      %{type: type} = violation when type in [:forbidden_dependency, "forbidden_dependency"] ->
        IO.puts(
          "  #{Format.loc(violation.file, violation.line)} #{violation.caller_layer} -> #{violation.callee_layer} " <>
            "#{violation.call}"
        )

      %{type: type} = violation when type in [:layer_cycle, "layer_cycle"] ->
        IO.puts("  layer cycle: #{Enum.join(closed_cycle(violation.layers), " -> ")}")
        render_layer_cycle_edges(Map.get(violation, :edges, []))

      %{type: type} = violation when type in [:forbidden_call, "forbidden_call"] ->
        IO.puts(
          "  #{Format.loc(violation.file, violation.line)} #{violation.caller_module} calls #{violation.call} (#{violation.rule})"
        )

      %{type: type} = violation when type in [:effect_policy, "effect_policy"] ->
        IO.puts([
          "  #{Format.loc(violation.file, violation.line)} #{violation.module}.#{violation.function} disallowed effects: ",
          Format.effects_join(violation.disallowed_effects)
        ])

      %{type: type} = violation
      when type in [
             :public_api_boundary,
             :internal_boundary,
             "public_api_boundary",
             "internal_boundary"
           ] ->
        IO.puts(
          "  #{Format.loc(violation.file, violation.line)} #{violation.caller_module} -> #{violation.callee_module} #{violation.call} (#{violation.rule})"
        )
    end)
  end

  def render_changed_text(result) do
    IO.puts(Format.header("Changed Code"))
    IO.puts("  base=#{result.base} risk=#{risk_label(result.risk)}")

    if result.risk_reasons != [] do
      IO.puts("  reasons=#{Enum.join(result.risk_reasons, ", ")}")
    end

    []
    |> add_omitted(
      render_limited_section("Changed files", result.changed_files, &IO.puts("  #{&1}"))
    )
    |> add_omitted(
      render_limited_section("Changed functions", result.changed_functions, fn function ->
        IO.puts(
          "  #{Format.bright(function.id)} #{Format.loc(function.file, function.line)} risk=#{risk_label(function.risk)} callers=#{function.direct_caller_count}/#{function.transitive_caller_count} branches=#{function.branch_count} effects=#{Format.effects_join(function.effects)}"
        )

        render_clone_siblings(function.clone_siblings)
      end)
    )
    |> add_omitted(
      render_limited_section("Public API touched", result.public_api_changes, fn function ->
        IO.puts("  #{Format.bright(function.id)} #{Format.loc(function.file, function.line)}")
      end)
    )
    |> add_omitted(
      render_limited_section(
        "Suggested tests",
        result.suggested_tests,
        &IO.puts("  mix test #{&1}")
      )
    )
    |> render_omitted_summary()
  end

  defp closed_cycle([]), do: []
  defp closed_cycle(nil), do: []
  defp closed_cycle([first | _] = layers), do: layers ++ [first]

  defp render_layer_cycle_edges([]), do: :ok
  defp render_layer_cycle_edges(nil), do: :ok

  defp render_layer_cycle_edges(edges) do
    IO.puts("")

    Enum.each(edges, fn edge ->
      IO.puts("    #{edge.caller_layer} -> #{edge.callee_layer}")
      IO.puts("      #{Format.loc(edge.file, edge.line)}")
      IO.puts("      #{edge.caller_module} -> #{edge.call}")
    end)
  end

  defp render_clone_siblings([]), do: :ok
  defp render_clone_siblings(nil), do: :ok

  defp render_clone_siblings(siblings) do
    IO.puts("    #{Format.faint("similar cloned functions may need matching updates:")}")

    siblings
    |> Enum.take(3)
    |> Enum.each(fn sibling ->
      IO.puts("      #{sibling.id} #{Format.loc(sibling.file, sibling.line)}")
    end)
  end

  defp render_representative_calls(%{representative_calls: calls})
       when is_list(calls) and calls != [] do
    IO.puts("    representative calls:")

    Enum.each(calls, fn call ->
      IO.puts("      #{Format.loc(call.file, call.line)} #{call.caller_module} -> #{call.call}")
    end)
  end

  defp render_representative_calls(_candidate), do: :ok

  defp render_limited_section(_title, [], _render_fun), do: nil

  defp render_limited_section(title, items, render_fun) do
    item_count = length(items)
    IO.puts("\n#{Format.section("#{title} (#{item_count})")}")

    items
    |> Enum.take(@text_limit)
    |> Enum.each(render_fun)

    omitted = item_count - @text_limit

    if omitted > 0, do: {title, omitted}
  end

  defp add_omitted(omitted, nil), do: omitted
  defp add_omitted(omitted, entry), do: [entry | omitted]

  defp render_omitted_summary([]), do: :ok

  defp render_omitted_summary(omitted) do
    summary =
      omitted
      |> Enum.reverse()
      |> Enum.map(fn {title, count} -> [title, ": ", to_string(count)] end)
      |> Enum.intersperse(", ")
      |> IO.iodata_to_binary()

    IO.puts(
      "\n" <>
        Format.omitted("Output truncated (#{summary}). Use --format json for complete output.")
    )
  end

  defp risk_label(risk), do: Format.risk(risk)

  defp json_envelope(result) do
    %Reach.CLI.JSONEnvelope{
      command: Map.get(result, :command, "reach.check"),
      data: Map.delete(result, :command)
    }
  end
end
