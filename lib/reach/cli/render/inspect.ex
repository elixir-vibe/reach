defmodule Reach.CLI.Render.Inspect do
  @moduledoc false

  alias Reach.CLI.Format
  alias Reach.CLI.Requirements
  alias Reach.Inspect.Context
  alias Reach.IR.Helpers, as: IRHelpers

  def render_why(result, "json"), do: render_json(result)
  def render_why(result, _format), do: render_why_text(result)

  def render_context(context, "json") do
    context
    |> format_context()
    |> Map.put(:command, "reach.inspect")
    |> render_json()
  end

  def render_context(
        %{
          mfa: mfa,
          func: func,
          data: data,
          direct_callers: direct,
          transitive_callers: transitive,
          callees: callees
        },
        _format,
        limit
      ) do
    IO.puts(Format.header("Reach context: #{IRHelpers.func_id_to_string(mfa)}"))
    IO.puts("  location: #{format_location(Context.location(func))}")
    IO.puts("  effects: #{Format.effects_join(Context.effects(func))}")
    IO.puts("  callers: #{length(direct)} direct, #{length(transitive)} transitive")

    IO.puts(
      "  data: #{length(data.definitions)} definitions, #{length(data.uses)} uses, #{length(data.returns)} returns"
    )

    IO.puts(Format.section("Callers"))
    render_limited(Enum.map(direct, &format_call/1), limit, &IO.puts("  #{&1}"))

    IO.puts(Format.section("Callees"))
    render_limited(Enum.map(callees, &format_callee_line/1), limit, &IO.puts("  #{&1}"))

    IO.puts(Format.section("Definitions"))
    render_limited(Enum.map(data.definitions, &format_var_summary/1), limit, &IO.puts("  #{&1}"))

    IO.puts(Format.section("Uses"))
    render_limited(Enum.map(data.uses, &format_var_summary/1), limit, &IO.puts("  #{&1}"))

    IO.puts(Format.section("Returns"))
    render_limited(Enum.map(data.returns, &format_return_summary/1), limit, &IO.puts("  #{&1}"))
  end

  def render_data(summary, mfa, func, "json") do
    render_json(%{
      command: "reach.inspect",
      target: IRHelpers.func_id_to_string(mfa),
      location: Context.location(func),
      data: summary
    })
  end

  def render_data(summary, _mfa, _func, _format) do
    IO.puts("Definitions:")
    Enum.each(summary.definitions, &IO.puts("  #{&1.name} #{Format.loc(&1.file, &1.line)}"))

    IO.puts("Uses:")
    Enum.each(summary.uses, &IO.puts("  #{&1.name} #{Format.loc(&1.file, &1.line)}"))

    IO.puts("Returns:")
    Enum.each(summary.returns, &IO.puts("  #{&1.kind} #{Format.loc(&1.file, &1.line)}"))
  end

  def render_candidates(%{target: target, candidates: []}, "json"),
    do:
      render_json(%{
        command: "reach.inspect",
        target: target,
        candidates: [],
        note: "Candidates are advisory. Prove behavior preservation before editing."
      })

  def render_candidates(result, "json"), do: render_json(result)

  def render_candidates(%{target: target, candidates: []}, _format) do
    IO.puts("Refactoring candidates for #{target}")
    IO.puts("")
    IO.puts("No graph-backed candidates found.")
  end

  def render_candidates(%{target: target, candidates: candidates, note: note}, _format) do
    IO.puts("Refactoring candidates for #{target}")
    IO.puts(note)
    IO.puts("")

    Enum.each(candidates, fn candidate ->
      IO.puts("#{candidate.id} #{Format.humanize(candidate.kind)}")

      IO.puts(
        "  benefit=#{candidate.benefit} risk=#{candidate.risk} confidence=#{Map.get(candidate, :confidence, :unknown)}"
      )

      IO.puts("  location=#{Format.loc(candidate.file, candidate.line)}")
      IO.puts("  evidence=#{Format.humanized_join(candidate.evidence)}")
      IO.puts("  suggestion=#{candidate.suggestion}")
      IO.puts("")
    end)
  end

  def render_cfg_header(fun, arity), do: IO.puts(Format.header("#{fun}/#{arity}"))
  def render_missing_source, do: IO.puts("  (no source file available)")

  defp render_why_text(%{paths: []} = result) do
    IO.puts(Format.header("Why #{result.target} -> #{result.why}"))

    message =
      case result.reason do
        nil -> "No #{result.relation} found."
        "source_not_found" -> "Source target could not be resolved."
        "target_not_found" -> "Why target could not be resolved."
        reason -> "No relationship found (#{reason})."
      end

    IO.puts("  #{message}")
  end

  defp render_why_text(result) do
    IO.puts(Format.header("Why #{result.target} -> #{result.why}"))
    IO.puts("Relation: #{result.relation}")

    Enum.each(result.paths, fn path ->
      IO.puts(Format.section("Path"))
      Enum.each(path.nodes, &render_why_node/1)

      if path.evidence != [] do
        IO.puts(Format.section("Evidence"))
        Enum.each(path.evidence, &render_why_evidence/1)
      end
    end)
  end

  defp render_why_node(%{function: function, file: file, line: line}) do
    IO.puts("  #{Format.bright(function)}")
    if file && line, do: IO.puts("    #{Format.loc(file, line)}")
  end

  defp render_why_node(%{module: module, file: file, line: line}) do
    IO.puts("  #{Format.bright(module)}")
    if file && line, do: IO.puts("    #{Format.loc(file, line)}")
  end

  defp render_why_evidence(evidence) do
    IO.puts("  #{evidence.from} -> #{evidence.to}")
    IO.puts("    #{evidence.call} #{Format.loc(evidence.file, evidence.line)}")
    if evidence.source, do: IO.puts("    #{evidence.source}")
  end

  defp format_location(%{file: file, line: line}) when is_binary(file) and is_integer(line),
    do: Format.loc(file, line)

  defp format_location(_location), do: "unknown"

  defp render_limited([], _limit, _render_fun), do: IO.puts("  " <> Format.empty())
  defp render_limited(items, :all, render_fun), do: Enum.each(items, render_fun)

  defp render_limited(items, limit, render_fun) do
    shown = Enum.take(items, limit)
    Enum.each(shown, render_fun)
    remaining = length(items) - length(shown)

    if remaining > 0 do
      IO.puts(
        "  " <>
          Format.omitted("#{remaining} more omitted. Use --limit N, --all, or --format json.")
      )
    end
  end

  defp format_callee_line(%{id: id, depth: depth}),
    do: String.duplicate("  ", depth - 1) <> IRHelpers.func_id_to_string(id)

  defp format_var_summary(item) do
    location = if item.file && item.line, do: Format.loc(item.file, item.line), else: "unknown"
    "#{item.name} #{location}"
  end

  defp format_return_summary(item) do
    location = if item.file && item.line, do: Format.loc(item.file, item.line), else: "unknown"
    "#{item.kind} #{location}"
  end

  defp format_context(context) do
    %{
      target: IRHelpers.func_id_to_string(context.target),
      location: context.location,
      effects: context.effects,
      deps: %{
        callers: Enum.map(context.deps.callers, &format_call/1),
        callees: Enum.map(context.deps.callees, &format_callee/1)
      },
      impact: %{
        direct_callers: Enum.map(context.impact.direct_callers, &format_call/1),
        transitive_callers: Enum.map(context.impact.transitive_callers, &format_call/1)
      },
      data: context.data
    }
  end

  defp format_call(%{id: id}), do: IRHelpers.func_id_to_string(id)

  defp format_callee(%{id: id, depth: depth, children: children}) do
    %{
      id: IRHelpers.func_id_to_string(id),
      depth: depth,
      children: Enum.map(children, &format_callee/1)
    }
  end

  defp render_json(data) do
    Requirements.json!()
    IO.puts(JSON.encode!(json_envelope(data)))
  end

  defp json_envelope(%{command: command} = data) do
    %Reach.CLI.JSONEnvelope{command: command, data: Map.delete(data, :command)}
  end

  defp json_envelope(data), do: %Reach.CLI.JSONEnvelope{command: "reach.inspect", data: data}
end
