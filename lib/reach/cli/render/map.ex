defmodule Reach.CLI.Render.Map do
  @moduledoc false

  @compile {:no_warn_undefined, [Boxart.Render.PieChart, Boxart.Render.PieChart.PieChart]}
  @dialyzer {:nowarn_function, render_depth_row_graph: 2}

  alias Reach.CLI.BoxartGraph
  alias Reach.CLI.Format
  alias Reach.CLI.Requirements
  alias Reach.Project.Query

  @section_order [:hotspots, :boundaries, :coupling, :modules, :effects, :depth, :data, :xref]

  def render(result, "json") do
    Requirements.json!()
    IO.puts(JSON.encode!(json_envelope(result)))
  end

  def render(result, "oneline"), do: render_oneline_map(result)
  def render(result, _format), do: render_text_map(result)

  def render_graph(project, sections, data) do
    BoxartGraph.require!()

    cond do
      :coupling in sections or :modules in sections ->
        BoxartGraph.render_module_graph(project)

      :effects in sections ->
        render_effect_graph(data.effects)

      :depth in sections ->
        render_depth_graph(project, data.depth)

      true ->
        Mix.raise(
          "--graph is supported with --modules, --coupling, or --depth. For target graphs, use mix reach.inspect TARGET --graph"
        )
    end
  end

  defp render_text_map(%{summary: summary, sections: sections}) do
    if map_size(sections) == 1 do
      [{key, data}] = Map.to_list(sections)
      IO.puts(Format.header(section_header(key, data)))
      render_text_section(key, data)
    else
      IO.puts(Format.header("Reach Map"))
      IO.puts("  modules=#{summary.modules} functions=#{summary.functions}")

      IO.puts(
        "  call_graph=#{summary.call_graph_vertices} vertices/#{summary.call_graph_edges} edges"
      )

      IO.puts("  dependence_graph=#{summary.graph_nodes} nodes/#{summary.graph_edges} edges")

      IO.puts(
        "  suppressions=#{summary.suppressions.total} reasonless=#{summary.suppressions.reasonless}"
      )

      Enum.each(ordered_sections(sections), fn {key, data} ->
        IO.puts(Format.section(section_title(key)))
        render_text_section(key, data)
      end)
    end
  end

  defp render_oneline_map(%{summary: summary, sections: sections}) do
    IO.puts(
      "summary modules=#{summary.modules} functions=#{summary.functions} call_edges=#{summary.call_graph_edges} graph_edges=#{summary.graph_edges} suppressions=#{summary.suppressions.total} reasonless_suppressions=#{summary.suppressions.reasonless}"
    )

    Enum.each(ordered_sections(sections), fn
      {:modules, modules} ->
        Enum.each(
          modules,
          &IO.puts(
            "module #{&1.name} functions=#{&1.total_functions} complexity=#{&1.total_complexity}"
          )
        )

      {:hotspots, hotspots} ->
        Enum.each(
          hotspots,
          &IO.puts(
            "hotspot #{&1.function} score=#{&1.score} branches=#{&1.branches} callers=#{&1.callers}"
          )
        )

      {:boundaries, boundaries} ->
        Enum.each(
          boundaries,
          &IO.puts("boundary #{&1.function} effects=#{Enum.join(&1.effects, "+")}")
        )

      {:effects, %{distribution: distribution, sources: sources}} ->
        Enum.each(distribution, fn row -> IO.puts("effect #{row.effect}=#{row.count}") end)

        Enum.each(sources, fn row ->
          IO.puts("effect_source #{effect_source_label(row)}=#{row.count}")
        end)

      {:effects, effects} ->
        Enum.each(effects, fn {effect, count} -> IO.puts("effect #{effect}=#{count}") end)

      {:data, data} ->
        Enum.each(data.top_functions, &IO.puts("data #{&1.function} edges=#{&1.data_edges}"))

        Enum.each(
          data.cross_function_edges || [],
          &IO.puts("xref #{&1.from} -> #{&1.to} edges=#{&1.edges}")
        )

      {:coupling, data} ->
        Enum.each(
          data.modules,
          &IO.puts("coupling #{&1.name} ca=#{&1.afferent} ce=#{&1.efferent} i=#{&1.instability}")
        )

      {:depth, rows} ->
        Enum.each(
          rows,
          &IO.puts("depth #{&1.function} depth=#{&1.depth} branches=#{&1.branch_count}")
        )
    end)
  end

  defp render_text_section(:modules, []), do: IO.puts("  " <> Format.empty())

  defp render_text_section(:modules, modules) do
    Enum.each(modules, fn module ->
      behaviours = module_behaviour_label(module.callbacks)
      IO.puts("  #{Format.bright(module.name)}#{Format.cyan(behaviours)}")

      IO.puts(
        "    #{module.public_count} public, #{module.private_count} private, complexity #{module.total_complexity}"
      )

      if module.biggest_function,
        do: IO.puts("    biggest: #{Format.yellow(module.biggest_function)}")

      if module.file, do: IO.puts("    #{Format.faint(Format.path(module.file))}")
      IO.puts("")
    end)
  end

  defp render_text_section(:hotspots, []), do: IO.puts("  " <> Format.empty())

  defp render_text_section(:hotspots, hotspots) do
    IO.puts("  #{Format.faint("score combines branch count with caller impact")}")

    Enum.each(hotspots, fn hotspot ->
      label = Map.get(hotspot, :display_function, hotspot.function)

      IO.puts(
        "  #{Format.bright(label)} score=#{hotspot.score} branches=#{hotspot.branches} callers=#{hotspot.callers}"
      )

      IO.puts("    #{Format.loc(hotspot.file, hotspot.line)}")
    end)
  end

  defp render_text_section(:coupling, %{modules: [], cycles: []}),
    do: IO.puts("  " <> Format.empty())

  defp render_text_section(:coupling, %{modules: modules, cycles: cycles}) do
    IO.puts(
      "  #{Format.faint("incoming=afferent dependencies, outgoing=efferent dependencies, instability=outgoing/(incoming+outgoing)")}"
    )

    Enum.each(modules, fn module ->
      IO.puts(
        "  #{Format.bright(module.name)} incoming=#{Format.count(module.afferent)} outgoing=#{Format.count(module.efferent)} instability=#{instability_label(module.instability)}"
      )
    end)

    if cycles != [] do
      IO.puts("  cycles:")
      Enum.each(cycles, &IO.puts("    #{Enum.join(&1.modules, " -> ")}"))
    end
  end

  defp render_text_section(:effects, %{distribution: [], unknown_calls: []}),
    do: IO.puts("  " <> Format.empty())

  defp render_text_section(:effects, %{
         distribution: distribution,
         sources: sources,
         unknown_calls: unknown_calls
       }) do
    Enum.each(distribution, fn row ->
      IO.puts("  #{Format.effect(row.effect)}: #{row.count} (#{percent(row.ratio)})")
    end)

    if sources != [] do
      IO.puts("  classification sources:")

      Enum.each(sources, fn row ->
        IO.puts("    #{effect_source_label(row)}: #{row.count} (#{percent(row.ratio)})")
      end)
    end

    if unknown_calls != [] do
      IO.puts("  unknown calls:")

      Enum.each(unknown_calls, fn call ->
        IO.puts("    #{call.module}.#{call.function} [#{call.kind}]: #{call.count}")
      end)
    end
  end

  defp render_text_section(:effects, []), do: IO.puts("  " <> Format.empty())

  defp render_text_section(:effects, effects),
    do:
      Enum.each(effects, fn {effect, count} -> IO.puts("  #{Format.effect(effect)}: #{count}") end)

  defp render_text_section(:boundaries, []), do: IO.puts("  " <> Format.empty())

  defp render_text_section(:boundaries, boundaries) do
    Enum.each(boundaries, fn boundary ->
      IO.puts(
        "  #{Format.bright(boundary.display_function)} effects=#{Format.effects_join(boundary.effects, "+")}"
      )

      Enum.each(boundary.calls, fn call ->
        IO.puts("    #{Format.effect(call.effect)} #{call.call}")
      end)

      IO.puts("    #{Format.loc(boundary.file, boundary.line)}")
    end)
  end

  defp render_text_section(:depth, []), do: IO.puts("  " <> Format.empty())

  defp render_text_section(:depth, rows) do
    Enum.each(rows, fn row ->
      IO.puts("  #{Format.bright(row.function)} depth=#{row.depth} branches=#{row.branch_count}")
      IO.puts("    #{Format.loc(row.file, row.line)}")
    end)
  end

  defp render_text_section(:data, data) do
    IO.puts("  total_data_edges=#{data.total_data_edges}")

    IO.puts(
      "  #{Format.faint("parameter_in flows into a call; parameter_out flows from a call result")}"
    )

    render_cross_function_flows(Map.get(data, :cross_function_edges, []))
    render_top_data_functions(data.top_functions)
  end

  defp effect_source_label(%{
         source: :plugin,
         classifier: classifier,
         confidence: confidence
       })
       when not is_nil(classifier),
       do: "plugin (#{classifier}) [#{confidence}]"

  defp effect_source_label(%{source: source, confidence: confidence}),
    do: "#{source} [#{confidence}]"

  defp render_cross_function_flows([]) do
    IO.puts("\n  Cross-function flows:")
    IO.puts("    " <> Format.empty())
  end

  defp render_cross_function_flows(edges) do
    IO.puts("\n  Cross-function flows:")
    Enum.each(edges, &render_cross_function_flow/1)
  end

  defp render_cross_function_flow(row) do
    labels =
      row.labels
      |> Enum.map(fn {label, count} -> [to_string(label), "=", to_string(count)] end)
      |> Enum.intersperse(", ")
      |> IO.iodata_to_binary()

    variables = Enum.join(row.variables, ", ")
    IO.puts("    #{Format.bright(row.from)} → #{Format.bright(row.to)} edges=#{row.edges}")
    IO.puts("      labels: #{labels}")
    if variables != "", do: IO.puts("      vars: #{variables}")
  end

  defp render_top_data_functions([]) do
    IO.puts("\n  Functions by data edges:")
    IO.puts("    " <> Format.empty())
  end

  defp render_top_data_functions(rows) do
    IO.puts("\n  Functions by data edges:")

    Enum.each(rows, fn row ->
      IO.puts("    #{Format.bright(row.function)} data_edges=#{row.data_edges}")
      IO.puts("      #{Format.loc(row.file, row.line)}")
    end)
  end

  defp ordered_sections(sections) do
    Enum.sort_by(sections, fn {key, _data} ->
      Enum.find_index(@section_order, &(&1 == key)) || 999
    end)
  end

  defp percent(value) when is_float(value),
    do: :erlang.float_to_binary(value * 100, decimals: 1) <> "%"

  defp percent(value), do: to_string(value)

  defp instability_label(value) when is_number(value) and value >= 0.8,
    do: Format.yellow(to_string(value))

  defp instability_label(value) when is_number(value), do: to_string(value)
  defp instability_label(value), do: to_string(value)

  defp section_title(:modules), do: "Modules"
  defp section_title(:hotspots), do: "Hotspots"
  defp section_title(:coupling), do: "Coupling"
  defp section_title(:effects), do: "Effects"
  defp section_title(:boundaries), do: "Effect Boundaries"
  defp section_title(:depth), do: "Control Depth"
  defp section_title(:data), do: "Data Flow"

  defp section_header(:modules, data), do: "Modules (#{length(data)})"
  defp section_header(:hotspots, data), do: "Hotspots (#{length(data)})"
  defp section_header(:coupling, data), do: "Module Coupling (#{length(data.modules)})"
  defp section_header(:effects, data), do: "Effect Distribution (#{data.total_calls} calls)"
  defp section_header(:boundaries, data), do: "Effect Boundaries (#{length(data)})"
  defp section_header(:depth, data), do: "Dominator Depth (#{length(data)})"
  defp section_header(:data, data), do: "Data Flow (#{length(data.top_functions)})"

  defp render_depth_graph(_project, []), do: IO.puts("  (no functions found)")
  defp render_depth_graph(project, [row | _]), do: render_depth_row_graph(project, row)

  defp render_depth_row_graph(project, row) do
    func = Query.find_function_at_location(project, row.file, row.line)

    if func do
      BoxartGraph.render_cfg(func, row.file)
      :ok
    else
      Mix.raise("Function not found: #{row.function}")
    end
  end

  defp module_behaviour_label([]), do: ""
  defp module_behaviour_label([behaviour | _]) when is_binary(behaviour), do: " (#{behaviour})"
  defp module_behaviour_label(_callbacks), do: ""

  defp render_effect_graph(result) do
    BoxartGraph.require_pie_chart!()
    chart_module = Module.concat([Boxart, Render, PieChart, PieChart])

    slices =
      result.distribution
      |> Enum.reject(&(&1.count == 0))
      |> Enum.map(&{&1.effect, &1.ratio * 100})

    chart =
      struct!(chart_module,
        title: "Effect Distribution (#{result.total_calls} calls)",
        slices: slices,
        show_data: true
      )

    IO.puts(Boxart.Render.PieChart.render(chart))
  end

  defp json_envelope(%{command: command} = data),
    do: %Reach.CLI.JSONEnvelope{command: command, data: Map.delete(data, :command)}
end
