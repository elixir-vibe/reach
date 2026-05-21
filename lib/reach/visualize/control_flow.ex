defmodule Reach.Visualize.ControlFlow do
  @moduledoc "Decomposes CFG into visualization blocks and edges."

  alias Reach.{ControlFlow, IR}
  alias Reach.Visualize.Source

  import Reach.Visualize.Helpers
  import Reach.Visualize.Source

  def build(all_nodes, _graph) do
    modules =
      all_nodes
      |> Enum.filter(&(&1.type == :module_def))
      |> Enum.map(fn mod ->
        file = span_field(mod, :file)

        func_nodes =
          IR.all_nodes(mod)
          |> Enum.filter(&(&1.type == :function_def))
          |> Enum.sort_by(&(span_field(&1, :start_line) || 0))

        functions = Enum.map(func_nodes, &build_function(&1, file))

        %{
          module: inspect(mod.meta[:name]),
          file: file,
          functions: functions
        }
      end)

    top_funcs = find_top_level_functions(all_nodes, modules)

    if top_funcs != [] do
      file = Enum.find_value(top_funcs, &span_field(&1, :file))

      top = %{
        module: nil,
        file: file,
        functions: Enum.map(top_funcs, &build_function(&1, file))
      }

      [top | modules]
    else
      modules
    end
  end

  # ── Function builder ──

  @doc false
  def build_function(func, file) do
    start_line = span_field(func, :start_line) || 1

    if func.meta[:language] == :javascript and func.meta[:source] do
      inject_js_source_cache(file, func.meta[:source], start_line)
    else
      Source.ensure_def_cache(file)
    end

    function_clauses =
      func.children
      |> Enum.filter(&(&1.type == :clause and &1.meta[:kind] == :function_clause))

    {nodes, edges} =
      if match?([_, _ | _], function_clauses) do
        build_multi_clause_cfg(func, function_clauses, file, start_line)
      else
        build_expression_nodes(func, file, start_line)
      end

    %{
      id: to_string(func.id),
      name: to_string(func.meta[:name]),
      arity: func.meta[:arity] || 0,
      nodes: nodes,
      edges: edges
    }
  end

  defp inject_js_source_cache(file, source, start_line) do
    cache_key = {:reach_file_lines, file}
    source_lines = String.split(source, "\n")
    padding = List.duplicate("", max(start_line - 1, 0))
    Process.put(cache_key, padding ++ source_lines)
    Process.put({:reach_file_lang, file}, :javascript)
  end

  # ── Multi-clause with CFG decomposition ──

  defp build_multi_clause_cfg(func, clauses, file, func_start) do
    func_end = func_end_line(func, file)

    if func_end <= func_start do
      source = Source.extract_func_source(func)
      fallback_single_block(func, source, func_start)
    else
      build_multi_clause_from_cfg(func, clauses, file, func_start, func_end)
    end
  end

  defp build_multi_clause_from_cfg(func, clauses, file, func_start, func_end) do
    cfg = ControlFlow.build(func)
    all_ir = IR.all_nodes(func)
    node_map = Map.new(all_ir, &{&1.id, &1})
    clause_ids = MapSet.new(clauses, & &1.id)

    ir_vertices = collect_ir_vertices(cfg, node_map, clause_ids, func_start)

    if ir_vertices == [] do
      source = Source.extract_func_source(func)
      fallback_single_block(func, source, func_start)
    else
      build_multi_clause_blocks(
        func,
        clauses,
        cfg,
        ir_vertices,
        node_map,
        file,
        func_start,
        func_end
      )
    end
  end

  defp collect_ir_vertices(cfg, node_map, clause_ids, func_start) do
    cfg
    |> Graph.vertices()
    |> Enum.filter(fn v ->
      is_integer(v) and Map.has_key?(node_map, v) and
        (v in clause_ids or
           span_field(Map.get(node_map, v), :start_line) not in [nil, func_start])
    end)
    |> Enum.sort_by(fn v ->
      span_field(Map.get(node_map, v), :start_line) || func_start
    end)
  end

  defp build_multi_clause_blocks(
         func,
         clauses,
         cfg,
         ir_vertices,
         node_map,
         file,
         func_start,
         func_end
       ) do
    func_id = to_string(func.id)
    name = func.meta[:name]
    arity = func.meta[:arity] || 0

    vertex_ranges = compute_vertex_ranges(ir_vertices, node_map, func_start, func_end)
    vertex_ranges = adjust_clause_ranges(clauses, vertex_ranges, func_start, func_end)

    branch_vertices = detect_branches(cfg)

    blocks = build_viz_blocks(ir_vertices, cfg, vertex_ranges, branch_vertices)
    blocks = merge_same_line_blocks(blocks, vertex_ranges, branch_vertices)

    viz_nodes =
      blocks_to_viz_nodes(blocks, vertex_ranges, branch_vertices, node_map, file, cfg)

    block_for_vertex = build_block_map(blocks)
    viz_edges = build_viz_edges(cfg, block_for_vertex, branch_vertices, node_map)

    dispatch_edges = build_dispatch_edges(clauses, block_for_vertex, func_id)

    entry =
      make_node(
        func_id,
        :entry,
        "#{name}/#{arity}",
        func_start,
        func_start,
        highlight_line(file, func_start)
      )

    {exit_node, exit_edges} = build_exit_node(cfg, block_for_vertex, file, func_id, func_end)

    all_nodes = [entry | viz_nodes] ++ [exit_node]
    all_edges = dispatch_edges ++ viz_edges ++ exit_edges

    {all_nodes, all_edges}
  end

  defp adjust_clause_ranges(clauses, vertex_ranges, func_start, func_end) do
    Enum.reduce(clauses, vertex_ranges, fn clause, ranges ->
      child_start =
        clause.children
        |> Enum.flat_map(&collect_span_lines/1)
        |> Enum.min(fn -> nil end)

      if child_start && child_start > func_start do
        {_, current_end} = Map.get(ranges, clause.id, {child_start, func_end})
        Map.put(ranges, clause.id, {child_start, current_end})
      else
        ranges
      end
    end)
  end

  defp build_dispatch_edges(clauses, block_for_vertex, func_id) do
    for {clause, idx} <- Enum.with_index(clauses),
        target_block = Map.get(block_for_vertex, clause.id),
        target_block != nil do
      %{
        id: "dispatch_#{func_id}_#{clause.id}",
        source: func_id,
        target: target_block,
        label: clause_pattern(clause),
        edge_type: :branch,
        color: dispatch_color(idx)
      }
    end
  end

  defp build_exit_node(cfg, block_for_vertex, file, func_id, exit_line) do
    exit_id = "#{func_id}_exit"

    exit_node =
      make_node(
        exit_id,
        :exit,
        "end",
        exit_line,
        exit_line,
        exit_source_html(file, exit_line)
      )

    exit_edges = build_exit_edges(find_exit_predecessors(cfg, block_for_vertex), exit_id)

    {exit_node, exit_edges}
  end

  defp exit_source_html(file, line) do
    file
    |> highlight_line(line)
    |> fallback_html("end")
  end

  defp fallback_html(html, text) do
    if source_blank?(html), do: Source.highlight_source(text), else: html
  end

  defp build_exit_edges(exit_targets, exit_id) do
    case exit_targets do
      [_, _ | _] -> Enum.map(exit_targets, &converge_edge(&1, exit_id))
      _ -> Enum.map(exit_targets, &seq_edge(&1, exit_id))
    end
    |> Enum.reject(&is_nil/1)
  end

  defp collect_span_lines(node) do
    line = span_field(node, :start_line)
    child_lines = Enum.flat_map(node.children, &collect_span_lines/1)
    if line, do: [line | child_lines], else: child_lines
  end

  # ── CFG-based expression nodes ──

  defp build_expression_nodes(func, file, func_start) do
    func_end = func_end_line(func, file)

    if func_end <= func_start do
      source = Source.extract_func_source(func)
      fallback_single_block(func, source, func_start)
    else
      build_from_cfg(func, file, func_start, func_end)
    end
  end

  defp build_from_cfg(func, file, func_start, func_end) do
    cfg = ControlFlow.build(func)
    all_ir = IR.all_nodes(func)
    node_map = Map.new(all_ir, &{&1.id, &1})
    func_id = to_string(func.id)

    ir_vertices =
      cfg
      |> Graph.vertices()
      |> Enum.filter(fn v ->
        is_integer(v) and Map.has_key?(node_map, v) and
          span_field(Map.get(node_map, v), :start_line) not in [nil, func_start]
      end)
      |> Enum.sort_by(fn v -> span_field(Map.get(node_map, v), :start_line) || 0 end)

    if ir_vertices == [] do
      source = Source.extract_func_source(func)
      fallback_single_block(func, source, func_start)
    else
      vertex_ranges = compute_vertex_ranges(ir_vertices, node_map, func_start, func_end)
      branch_vertices = detect_branches(cfg)

      blocks = build_viz_blocks(ir_vertices, cfg, vertex_ranges, branch_vertices)
      blocks = merge_same_line_blocks(blocks, vertex_ranges, branch_vertices)

      viz_nodes = blocks_to_viz_nodes(blocks, vertex_ranges, branch_vertices, node_map, file, cfg)

      block_for_vertex = build_block_map(blocks)
      viz_edges = build_viz_edges(cfg, block_for_vertex, branch_vertices, node_map)

      entry =
        make_node(
          func_id,
          :entry,
          "#{func.meta[:name]}/#{func.meta[:arity]}",
          func_start,
          func_start,
          highlight_line(file, func_start)
        )

      {exit_node, exit_edges} = build_exit_node(cfg, block_for_vertex, file, func_id, func_end)

      first_block_id = find_entry_target(cfg, block_for_vertex)
      entry_edge = if first_block_id, do: seq_edge(func_id, first_block_id)

      all_nodes = [entry | viz_nodes] ++ [exit_node]
      all_edges = Enum.reject([entry_edge | viz_edges] ++ exit_edges, &is_nil/1)
      {all_nodes, all_edges}
    end
  end

  defp compute_vertex_ranges(ir_vertices, node_map, func_start, func_end) do
    lines =
      Enum.map(ir_vertices, fn v ->
        n = Map.fetch!(node_map, v)
        min_line_in_subtree(n) || func_start
      end)

    ir_vertices
    |> Enum.with_index()
    |> Map.new(fn {v, idx} ->
      start_l = Enum.at(lines, idx)
      next_l = Enum.at(lines, idx + 1)
      end_l = if next_l, do: next_l - 1, else: func_end - 1
      {v, {max(start_l, func_start + 1), max(start_l, end_l)}}
    end)
  end

  defp detect_branches(cfg) do
    edges = Graph.edges(cfg)

    {edge_sources, clause_targets} =
      Enum.reduce(edges, {[], []}, fn e, {srcs, tgts} ->
        cond do
          match?({:clause_match, _}, e.label) ->
            {[e.v1 | srcs], [e.v2 | tgts]}

          e.label in [:true_branch, :false_branch] ->
            {[e.v1 | srcs], tgts}

          true ->
            {srcs, tgts}
        end
      end)

    multi_out =
      edges
      |> Enum.group_by(& &1.v1)
      |> Enum.filter(fn {_, es} -> match?([_, _ | _], es) end)
      |> Enum.map(fn {v, _} -> v end)

    MapSet.new(edge_sources ++ clause_targets ++ multi_out)
  end

  defp build_viz_blocks(ir_vertices, cfg, _vertex_ranges, branch_vertices) do
    edges = Graph.edges(cfg)
    in_degree = Enum.frequencies_by(edges, & &1.v2)
    out_edges_by = Enum.group_by(edges, & &1.v1)

    ir_vertices
    |> Enum.reduce([], fn v, blocks ->
      try_merge_into_block(v, blocks, branch_vertices, in_degree, out_edges_by, cfg)
    end)
    |> Enum.reverse()
  end

  defp try_merge_into_block(
         v,
         [[prev_v | _] = prev_block | rest],
         branch_vertices,
         in_degree,
         out_edges_by,
         cfg
       ) do
    if mergeable_vertex?(v, branch_vertices, in_degree, out_edges_by) and
         sequential_prev?(prev_v, branch_vertices, out_edges_by) and
         connected_sequential?(last_in(prev_block), v, cfg) do
      [prev_block ++ [v] | rest]
    else
      [[v], prev_block | rest]
    end
  end

  defp try_merge_into_block(v, blocks, _bv, _in, _out, _cfg), do: [[v] | blocks]

  defp mergeable_vertex?(v, branch_vertices, in_degree, out_edges_by) do
    v not in branch_vertices and
      Map.get(in_degree, v, 0) <= 1 and
      not Enum.any?(Map.get(out_edges_by, v, []), &match?({:clause_match, _}, &1.label))
  end

  defp sequential_prev?(prev_v, branch_vertices, out_edges_by) do
    prev_v not in branch_vertices and
      not Enum.any?(Map.get(out_edges_by, prev_v, []), fn e ->
        match?({:clause_match, _}, e.label) or e.label in [:true_branch, :false_branch]
      end)
  end

  defp connected_sequential?(from, to, cfg) do
    Graph.edges(cfg, from, to) |> Enum.any?(&(&1.label == :sequential))
  end

  defp merge_same_line_blocks(blocks, vertex_ranges, branch_vertices) do
    blocks
    |> Enum.group_by(fn [first_v | _] ->
      {start_l, _} = Map.fetch!(vertex_ranges, first_v)
      start_l
    end)
    |> Enum.flat_map(fn {_line, group} ->
      merge_block_group(group, branch_vertices)
    end)
  end

  defp merge_block_group([_single] = group, _branch_vertices), do: group

  defp merge_block_group(group, branch_vertices) do
    {priority, seq} =
      Enum.split_with(group, fn block ->
        Enum.any?(block, &(&1 in branch_vertices))
      end)

    case {priority, seq} do
      {[], _} ->
        [List.flatten(group)]

      {[single], _seq} ->
        absorbed = List.flatten(seq)
        [single ++ absorbed]

      {_multiple, _} ->
        [List.flatten(group)]
    end
  end

  defp blocks_to_viz_nodes(blocks, vertex_ranges, branch_vertices, node_map, file, cfg) do
    all_starts =
      blocks
      |> Enum.map(fn [first_v | _] -> elem(Map.fetch!(vertex_ranges, first_v), 0) end)
      |> Enum.sort()

    blocks
    |> Enum.map(fn [first_v | _] = block ->
      {start_l, _} = Map.fetch!(vertex_ranges, first_v)

      raw_end_l =
        Enum.reduce(block, 0, fn v, acc -> max(elem(Map.fetch!(vertex_ranges, v), 1), acc) end)

      min_next = all_starts |> Enum.filter(&(&1 > start_l)) |> Enum.min(fn -> nil end)
      end_l = if min_next, do: min(raw_end_l, min_next - 1), else: raw_end_l

      node = Map.get(node_map, first_v)
      type = block_type(block, branch_vertices, node_map)
      label = block_label(type, node, block, node_map, cfg)
      block_id = "b_" <> Enum.map_join(block, "_", &to_string/1)

      source =
        if(type == :branch,
          do: highlight_line(file, start_l),
          else: highlight_lines(file, start_l, end_l)
        )

      make_node(block_id, type, label, start_l, end_l, source)
    end)
    |> Enum.reject(&(source_blank?(&1.source_html) and &1.type not in [:entry, :exit]))
  end

  defp last_in([last]), do: last
  defp last_in([_head | tail]), do: last_in(tail)

  defp source_blank?(nil), do: true

  defp source_blank?(html) do
    html
    |> String.replace(~r/<[^>]+>/, "")
    |> String.trim()
    |> Kernel.==("")
  end

  defp block_type(block, branch_vertices, node_map) do
    cond do
      Enum.any?(block, &(&1 in branch_vertices)) ->
        :branch

      Enum.any?(block, fn v ->
        n = Map.get(node_map, v)
        n && n.meta[:kind] in [:case_clause, :true_branch, :false_branch]
      end) ->
        :clause

      true ->
        :sequential
    end
  end

  defp block_label(:branch, node, block, node_map, cfg) do
    case find_case_node(block, node_map, cfg) do
      nil -> branch_label(node)
      case_node -> branch_label(case_node)
    end
  end

  defp block_label(:clause, node, block, node_map, _cfg) do
    clause_node =
      Enum.find_value(block, fn v ->
        n = Map.get(node_map, v)
        if n && n.meta[:kind] in [:case_clause, :true_branch, :false_branch], do: n
      end)

    clause_label(clause_node || node)
  end

  defp block_label(:sequential, node, [_single], _node_map, _cfg), do: ir_label(node)

  defp block_label(:sequential, node, block, node_map, _cfg) do
    label = ir_label(node)
    last = Map.get(node_map, last_in(block))

    if last && last != node do
      "#{label}..#{ir_label(last)}"
    else
      label
    end
  end

  defp find_case_node(block, node_map, cfg) do
    find_in_block(block, node_map) || find_in_predecessors(block, node_map, cfg)
  end

  defp find_in_block(block, node_map) do
    Enum.find_value(block, fn v ->
      n = Map.get(node_map, v)
      if n && n.type == :case, do: n
    end)
  end

  defp find_in_predecessors(block, node_map, cfg) do
    block
    |> Enum.flat_map(&cfg_sequential_predecessors(cfg, &1))
    |> Enum.find_value(fn v ->
      n = Map.get(node_map, v)
      if n && n.type == :case, do: n
    end)
  end

  defp cfg_sequential_predecessors(cfg, v) do
    cfg
    |> Graph.in_edges(v)
    |> Enum.filter(&(&1.label == :sequential and is_integer(&1.v1)))
    |> Enum.map(& &1.v1)
  end

  defp branch_label(%{meta: %{origin: %{label: label}}}) when is_binary(label), do: label
  defp branch_label(%{type: :case, meta: %{desugared_from: :if}}), do: "if"
  defp branch_label(%{type: :case, meta: %{desugared_from: :unless}}), do: "unless"
  defp branch_label(%{type: :case}), do: "case"
  defp branch_label(_), do: "branch"

  defp clause_patterns([]), do: []
  defp clause_patterns([pattern]), do: [pattern]
  defp clause_patterns([pattern | rest]), do: clause_patterns(rest, [pattern])

  defp clause_patterns([_body], acc), do: Enum.reverse(acc)
  defp clause_patterns([pattern | rest], acc), do: clause_patterns(rest, [pattern | acc])

  defp clause_label(%{meta: %{kind: :true_branch}}), do: "true"
  defp clause_label(%{meta: %{kind: :false_branch}}), do: "false"

  defp clause_label(%{meta: %{kind: :case_clause}, children: children}) do
    children
    |> clause_patterns()
    |> Enum.reject(&(&1.type == :guard))
    |> Enum.map_join(", ", &render_pattern/1)
    |> case do
      "" -> "_"
      s -> String.slice(s, 0, 50)
    end
  end

  defp clause_label(_), do: nil

  defp build_block_map(blocks) do
    for block <- blocks, v <- block, into: %{} do
      block_id = "b_" <> Enum.map_join(block, "_", &to_string/1)
      {v, block_id}
    end
  end

  defp build_viz_edges(cfg, block_for_vertex, branch_vertices, node_map) do
    cfg
    |> Graph.edges()
    |> Enum.flat_map(fn e ->
      resolve_edge(e, cfg, block_for_vertex, branch_vertices, node_map)
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&{&1.source, &1.target})
  end

  defp resolve_edge(e, cfg, block_map, branch_vertices, node_map) do
    src_block = resolve_to_block(e.v1, cfg, block_map, :in)
    tgt_block = resolve_to_block(e.v2, cfg, block_map, :out)

    if src_block && tgt_block && src_block != tgt_block do
      {edge_type, label, color} = classify_cfg_edge(e, branch_vertices, node_map)

      [
        %{
          id: "cfg_#{e.v1}_#{e.v2}",
          source: src_block,
          target: tgt_block,
          label: label,
          edge_type: edge_type,
          color: color
        }
      ]
    else
      []
    end
  end

  defp resolve_to_block(v, cfg, block_map, dir),
    do: resolve_to_block(v, cfg, block_map, dir, MapSet.new())

  defp resolve_to_block(v, _cfg, _block_map, _dir, _visited) when not is_integer(v), do: nil

  defp resolve_to_block(v, cfg, block_map, dir, visited) do
    if v in visited, do: nil, else: do_resolve(v, cfg, block_map, dir, MapSet.put(visited, v))
  end

  defp do_resolve(v, cfg, block_map, dir, visited) do
    case Map.get(block_map, v) do
      nil ->
        next_vertices =
          if dir == :out,
            do: Graph.out_edges(cfg, v) |> Enum.map(& &1.v2),
            else: Graph.in_edges(cfg, v) |> Enum.map(& &1.v1)

        Enum.find_value(next_vertices, fn nv ->
          resolve_to_block(nv, cfg, block_map, dir, visited)
        end)

      block_id ->
        block_id
    end
  end

  defp classify_cfg_edge(%{label: {:clause_match, idx}} = edge, _bv, node_map) do
    target_node = Map.get(node_map, edge.v2)

    label =
      if target_node, do: clause_label(target_node) || "clause #{idx}", else: "clause #{idx}"

    {:branch, label, dispatch_color(idx)}
  end

  defp classify_cfg_edge(%{label: :true_branch}, _bv, _nm), do: {:branch, "true", "#16a34a"}
  defp classify_cfg_edge(%{label: :false_branch}, _bv, _nm), do: {:branch, "false", "#dc2626"}
  defp classify_cfg_edge(%{label: :return}, _bv, _nm), do: {:sequential, "", "#94a3b8"}

  defp classify_cfg_edge(edge, branch_vertices, node_map) do
    target_kind = get_in(node_map, [edge.v2, Access.key(:meta, %{}), :kind])

    if edge.v2 in branch_vertices or target_kind in [:true_branch, :false_branch, :case_clause] do
      {:branch, "", "#94a3b8"}
    else
      {:sequential, "", "#94a3b8"}
    end
  end

  defp find_entry_target(cfg, block_for_vertex) do
    cfg
    |> Graph.out_edges(:entry)
    |> Enum.find_value(fn e -> resolve_to_block(e.v2, cfg, block_for_vertex, :out) end)
  end

  defp find_exit_predecessors(cfg, block_for_vertex) do
    cfg
    |> Graph.in_edges(:exit)
    |> Enum.map(fn e -> resolve_to_block(e.v1, cfg, block_for_vertex, :in) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # ── Fallback ──

  defp fallback_single_block(func, source, start_line) do
    lang = if func.meta[:language] == :javascript, do: :javascript, else: :elixir

    node =
      make_node(
        to_string(func.id),
        :entry,
        "#{func.meta[:name]}/#{func.meta[:arity]}",
        start_line,
        start_line,
        Source.highlight_source(source, lang)
      )

    {[node], []}
  end

  # ── Node/edge constructors ──

  defp make_node(id, type, label, start_line, end_line, source_html) do
    %{
      id: id,
      type: type,
      label: label,
      start_line: start_line,
      end_line: end_line,
      source_html: source_html,
      parent_id: nil
    }
  end

  defp seq_edge(source, target) when is_binary(source) and is_binary(target) do
    %{
      id: "seq_#{source}_#{target}",
      source: source,
      target: target,
      label: "",
      edge_type: :sequential,
      color: "#94a3b8"
    }
  end

  defp seq_edge(_, _), do: nil

  defp converge_edge(source, target) when is_binary(source) and is_binary(target) do
    %{
      id: "conv_#{source}_#{target}",
      source: source,
      target: target,
      label: "",
      edge_type: :converge,
      color: "#3b82f6"
    }
  end

  defp converge_edge(_, _), do: nil

  defp dispatch_color(0), do: "#16a34a"
  defp dispatch_color(1), do: "#2563eb"
  defp dispatch_color(2), do: "#ea580c"
  defp dispatch_color(_), do: "#7c3aed"

  defp find_top_level_functions(all_nodes, modules) do
    module_func_ids =
      modules
      |> Enum.flat_map(fn m -> Enum.map(m.functions, & &1.id) end)
      |> MapSet.new()

    all_nodes
    |> Enum.filter(&(&1.type == :function_def))
    |> Enum.reject(&(to_string(&1.id) in module_func_ids))
    |> Enum.sort_by(&(span_field(&1, :start_line) || 0))
  end
end
