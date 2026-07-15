defmodule Reach.Source.DSLGuard do
  @moduledoc "Locates AST ranges whose syntax has plugin-defined or configured DSL semantics."

  alias Reach.AST

  @type macro_shape :: {module() | nil, atom(), non_neg_integer() | :any}
  @type source_range :: %{
          start_line: pos_integer(),
          start_column: pos_integer() | nil,
          end_line: pos_integer(),
          end_column: pos_integer() | nil
        }

  @spec enabled?([module()], [macro_shape()]) :: boolean()
  def enabled?(plugins, shapes) do
    shapes != [] or guard_plugins(plugins) != []
  end

  @spec ranges(Macro.t(), [module()], [macro_shape()]) :: [source_range()]
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

    Enum.sort_by(ranges, &{&1.start_line, &1.start_column || 0, &1.end_line, &1.end_column || 0})
  end

  @spec guarded_line?([source_range()], pos_integer()) :: boolean()
  def guarded_line?(ranges, line), do: guarded_position?(ranges, line, nil)

  @spec guarded_position?([source_range()], pos_integer(), pos_integer() | nil) :: boolean()
  def guarded_position?(ranges, line, column) do
    Enum.any?(ranges, &position_in_range?(&1, line, column))
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
      nil -> ranges
      range -> [range | ranges]
    end
  end

  defp node_range(node) do
    case Sourceror.get_range(node) do
      %{start: start_position, end: end_position} ->
        with start_line when is_integer(start_line) <- position_line(start_position),
             end_line when is_integer(end_line) <- position_line(end_position) do
          %{
            start_line: start_line,
            start_column: position_column(start_position),
            end_line: max(start_line, end_line),
            end_column: position_column(end_position)
          }
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
      [] ->
        nil

      lines ->
        {start_line, end_line} = Enum.min_max(lines)

        %{
          start_line: start_line,
          start_column: nil,
          end_line: end_line,
          end_column: nil
        }
    end
  end

  defp position_line(position), do: position[:line]
  defp position_column(position), do: position[:column]

  defp position_in_range?(range, line, column) when is_integer(column) do
    after_start? =
      line > range.start_line or
        (line == range.start_line and
           (is_nil(range.start_column) or column >= range.start_column))

    before_end? =
      line < range.end_line or
        (line == range.end_line and (is_nil(range.end_column) or column < range.end_column))

    after_start? and before_end?
  end

  defp position_in_range?(range, line, _column) do
    line >= range.start_line and line <= range.end_line
  end
end
