defmodule Reach.Source.DSLGuard do
  @moduledoc "Locates AST ranges whose syntax has plugin-defined or configured DSL semantics."

  alias Reach.AST

  @type macro_shape :: {module() | nil, atom(), non_neg_integer() | :any}
  @type line_range :: %{start_line: pos_integer(), end_line: pos_integer()}

  @spec enabled?([module()], [macro_shape()]) :: boolean()
  def enabled?(plugins, shapes) do
    shapes != [] or guard_plugins(plugins) != []
  end

  @spec ranges(Macro.t(), [module()], [macro_shape()]) :: [line_range()]
  def ranges(ast, plugins, shapes) do
    guard_plugins = guard_plugins(plugins)

    {_ast, ranges} =
      Macro.prewalk(ast, [], fn node, ranges ->
        if reinterpreted?(node, guard_plugins, shapes) do
          {node, add_range(node, ranges)}
        else
          {node, ranges}
        end
      end)

    merge_ranges(ranges)
  end

  @spec guarded_line?([line_range()], pos_integer()) :: boolean()
  def guarded_line?(ranges, line) do
    Enum.any?(ranges, &(line >= &1.start_line and line <= &1.end_line))
  end

  defp reinterpreted?(node, plugins, shapes) do
    Enum.any?(plugins, & &1.reinterpreted_ast?(node)) or configured_shape?(node, shapes)
  end

  defp guard_plugins(plugins) do
    Enum.filter(
      plugins,
      &(Code.ensure_loaded?(&1) and function_exported?(&1, :reinterpreted_ast?, 1))
    )
  end

  defp configured_shape?(node, shapes) do
    case AST.call(node) do
      nil -> false
      {module, name, args} -> Enum.any?(shapes, &shape_matches?(&1, module, name, length(args)))
    end
  end

  defp shape_matches?({module, name, :any}, module, name, _arity), do: true
  defp shape_matches?({module, name, arity}, module, name, arity), do: true
  defp shape_matches?(_shape, _module, _name, _arity), do: false

  defp add_range(node, ranges) do
    case node_range(node) do
      {start_line, end_line} ->
        [%{start_line: start_line, end_line: max(start_line, end_line)} | ranges]

      nil ->
        ranges
    end
  end

  defp node_range(node) do
    case Sourceror.get_range(node) do
      %{start: start_position, end: end_position} ->
        with start_line when is_integer(start_line) <- position_line(start_position),
             end_line when is_integer(end_line) <- position_line(end_position) do
          {start_line, end_line}
        else
          _missing_position -> ast_line_bounds(node)
        end

      _range ->
        ast_line_bounds(node)
    end
  end

  defp ast_line_bounds(ast) do
    {_ast, lines} =
      Macro.prewalk(ast, [], fn
        {_form, meta, _args} = node, lines when is_list(meta) ->
          {node, if(is_integer(meta[:line]), do: [meta[:line] | lines], else: lines)}

        node, lines ->
          {node, lines}
      end)

    case lines do
      [] -> nil
      lines -> Enum.min_max(lines)
    end
  end

  defp position_line(position), do: position[:line]

  defp merge_ranges(ranges) do
    ranges
    |> Enum.sort_by(&{&1.start_line, &1.end_line})
    |> Enum.reduce([], &merge_range/2)
    |> Enum.reverse()
  end

  defp merge_range(range, [%{end_line: end_line} = current | rest])
       when range.start_line <= end_line + 1 do
    [%{current | end_line: max(end_line, range.end_line)} | rest]
  end

  defp merge_range(range, ranges), do: [range | ranges]
end
