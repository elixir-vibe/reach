defmodule Reach.Plugins.LiveView do
  @moduledoc "Plugin for LiveView and HEEx template semantics."
  @behaviour Reach.Plugin

  alias Reach.IR
  alias Reach.IR.Node
  alias Reach.Plugins.LiveView.HEEx

  @pure_local [
    :assign,
    :assign_new,
    :push_event,
    :push_patch,
    :push_navigate,
    :put_flash,
    :redirect,
    :live_render,
    :live_component,
    :on_mount,
    :__live_event__,
    :sigil_H,
    :sigil_p
  ]

  @pure_remote_modules [Phoenix.Component, Phoenix.LiveView]

  @assign_modules [nil, Phoenix.Component, Phoenix.LiveView]
  @event_attrs [:__live_event__]
  @event_functions [:push_event]
  @stream_functions [:stream, :stream_insert, :stream_delete]

  @impl true
  def analyze(all_nodes, _opts) do
    function_defs = Enum.filter(all_nodes, &(&1.type == :function_def))

    live_event_edges(function_defs) ++
      live_assign_edges(function_defs) ++
      live_component_attr_edges(function_defs) ++
      live_stream_edges(function_defs)
  end

  @impl true
  def source_extensions, do: [".heex"]

  @impl true
  def source_language(".heex"), do: :heex
  def source_language(_), do: nil

  @impl true
  def parse_file(path, opts), do: HEEx.parse_file(path, opts)

  @impl true
  def lower_elixir_ast({:sigil_H, meta, [{:<<>>, _, [source]}, modifiers]}, opts)
      when is_binary(source) and modifiers in [[], ~c"noformat"] do
    HEEx.lower_sigil(source, meta, opts)
  end

  def lower_elixir_ast(_ast, _opts), do: :ignore

  @impl true
  def classify_effect(%Node{type: :call, meta: %{kind: :local, function: fun}})
      when fun in @pure_local,
      do: :pure

  def classify_effect(%Node{type: :call, meta: %{kind: :remote, module: mod}})
      when mod in @pure_remote_modules,
      do: :pure

  def classify_effect(_), do: nil

  @impl true
  def behaviour_label(callbacks) do
    if :mount in callbacks and :render in callbacks, do: "LiveView"
  end

  @impl true
  def ignore_call_edge?(%Graph.Edge{v2: {Phoenix.LiveView.TagEngine, fun, _arity}})
      when fun in [:component, :inner_block],
      do: true

  def ignore_call_edge?(_edge), do: false

  defp live_event_edges(function_defs) do
    handlers = event_handlers(function_defs)

    for func <- function_defs,
        event_node <- func |> IR.all_nodes() |> Enum.filter(&live_event_node?/1),
        event = event_name(event_node),
        is_binary(event),
        handler <- Map.get(handlers, {func.meta[:module], event}, []) do
      {event_node.id, handler.id, {:live_event, event}}
    end
  end

  defp event_handlers(function_defs) do
    function_defs
    |> Enum.filter(&(&1.meta[:name] == :handle_event and &1.meta[:arity] == 3))
    |> Enum.flat_map(fn func ->
      func.children
      |> Enum.filter(&(&1.type == :clause))
      |> Enum.flat_map(&event_handler_clause(func, &1))
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp event_handler_clause(func, clause) do
    case clause.children do
      [%Node{type: :literal, meta: %{value: event}} | _] when is_binary(event) ->
        target = if clause.source_span, do: clause, else: func
        [{{func.meta[:module], event}, target}]

      _ ->
        []
    end
  end

  defp live_event_node?(%Node{type: :call, meta: %{function: fun}}) when fun in @event_attrs,
    do: true

  defp live_event_node?(%Node{type: :call, meta: %{function: fun}}) when fun in @event_functions,
    do: true

  defp live_event_node?(%Node{
         type: :call,
         meta: %{module: Phoenix.LiveView.JS, function: :push}
       }),
       do: true

  defp live_event_node?(%Node{type: :call, meta: %{module: JS, function: :push}}), do: true
  defp live_event_node?(_), do: false

  defp event_name(%Node{
         meta: %{function: :__live_event__},
         children: [%Node{type: :literal, meta: %{value: event}} | _]
       }),
       do: event

  defp event_name(%Node{children: [%Node{type: :literal, meta: %{value: event}} | _]})
       when is_binary(event),
       do: event

  defp event_name(_), do: nil

  defp live_assign_edges(function_defs) do
    live_key_edges(function_defs, &assign_writes/1, &assign_reads/1, :live_assign)
  end

  defp assign_writes(
         %Node{type: :call, meta: %{function: fun, module: module}, children: children} = node
       )
       when fun in [:assign, :assign_new, :assign_async] and module in @assign_modules do
    case children do
      [_socket, %Node{type: :literal, meta: %{value: key}} | _] when is_atom(key) ->
        [{key, node}]

      [_socket, %Node{type: :map, children: fields} | _] ->
        fields
        |> Enum.flat_map(&map_field_key/1)
        |> Enum.map(&{&1, node})

      _ ->
        []
    end
  end

  defp assign_writes(_), do: []

  defp assign_reads(
         %Node{
           type: :call,
           meta: %{function: :@},
           children: [%Node{type: :var, meta: %{name: key}}]
         } = node
       )
       when is_atom(key) and key not in [:streams, :uploads, :flash],
       do: [{key, node}]

  defp assign_reads(_), do: []

  defp live_component_attr_edges(function_defs) do
    for func <- function_defs,
        call <- IR.all_nodes(func),
        component_call?(call),
        attr <- component_attrs(call),
        var <- attr_vars(attr) do
      {var.id, call.id, {:live_component_attr, elem(attr, 0)}}
    end
  end

  # LiveView 1.1 fallback emits runtime component helper calls with generated
  # assigns maps and slot internals. Those are too noisy for attr-flow edges.
  # Parser-backed lowering emits direct component calls, which are safe to use.
  defp component_call?(%Node{type: :call, meta: %{module: Phoenix.LiveView.TagEngine}}), do: false

  defp component_call?(%Node{type: :call, meta: %{origin: %{kind: :component}}}), do: true
  defp component_call?(_), do: false

  defp component_attrs(%Node{children: children}) do
    children
    |> Enum.find(&(&1.type == :map))
    |> case do
      %Node{children: fields} ->
        Enum.flat_map(fields, &component_attr_field/1)

      _ ->
        []
    end
  end

  defp component_attrs(_), do: []

  defp component_attr_field(%Node{type: :map_field, children: [key_node, value_node]}) do
    case literal_key(key_node) do
      nil -> []
      key when key in [:inner_block, :__changed__, :__slot__] -> []
      key -> [{key, value_node}]
    end
  end

  defp component_attr_field(_field), do: []

  defp attr_vars({_key, value}) do
    value
    |> IR.all_nodes()
    |> Enum.filter(fn
      %Node{type: :var, source_span: %{}, meta: %{name: name}} ->
        name not in [:_, :__MODULE__, :__ENV__, :assigns]

      _ ->
        false
    end)
  end

  defp live_stream_edges(function_defs) do
    live_key_edges(function_defs, &stream_writes/1, &stream_reads/1, :live_stream)
  end

  defp live_key_edges(function_defs, write_fun, read_fun, edge_kind) do
    by_module =
      Enum.group_by(function_defs, & &1.meta[:module], fn func ->
        nodes = IR.all_nodes(func)

        %{
          writes: Enum.flat_map(nodes, write_fun),
          reads: Enum.flat_map(nodes, read_fun)
        }
      end)

    for {_module, groups} <- by_module,
        write <- Enum.flat_map(groups, & &1.writes),
        read <- Enum.flat_map(groups, & &1.reads),
        elem(write, 0) == elem(read, 0) do
      {_key, write_node} = write
      {_key, read_node} = read
      {write_node.id, read_node.id, {edge_kind, elem(write, 0)}}
    end
  end

  defp stream_writes(
         %Node{
           type: :call,
           meta: %{function: fun},
           children: [_socket, %Node{type: :literal, meta: %{value: key}} | _]
         } = node
       )
       when fun in @stream_functions and is_atom(key),
       do: [{key, node}]

  defp stream_writes(_), do: []

  defp stream_reads(
         %Node{type: :call, meta: %{kind: :field_access, function: key}, children: children} =
           node
       )
       when is_atom(key) do
    if Enum.any?(children, &streams_assign?/1), do: [{key, node}], else: []
  end

  defp stream_reads(_), do: []

  defp streams_assign?(%Node{
         type: :call,
         meta: %{function: :@},
         children: [%Node{type: :var, meta: %{name: :streams}}]
       }),
       do: true

  defp streams_assign?(_), do: false

  defp map_field_key(%Node{type: :map_field, children: [key_node | _]}) do
    case literal_key(key_node) do
      nil -> []
      key -> [key]
    end
  end

  defp map_field_key(_), do: []

  defp literal_key(%Node{type: :literal, meta: %{value: key}})
       when is_atom(key) or is_binary(key),
       do: key

  defp literal_key(_), do: nil
end
