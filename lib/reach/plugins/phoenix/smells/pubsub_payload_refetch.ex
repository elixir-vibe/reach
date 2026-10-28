defmodule Reach.Plugins.Phoenix.Smells.PubSubPayloadRefetch do
  @moduledoc """
  Detects `handle_info/2` clauses that take only the `id` from a PubSub
  payload the broadcaster already loaded, then query for the same record.

  A clause is reported only when the project also contains a PubSub
  broadcast whose message is a `{tag, payload}` tuple with the same literal
  tag and a payload that is more than an id (a non-id variable, or a
  map/struct literal with keys other than `:id`). Without a matching
  broadcaster the receiver cannot be told apart from a message that only
  ever carries an id, so it is skipped.
  """

  @behaviour Reach.Smell.Check

  alias Reach.Effects
  alias Reach.IR
  alias Reach.Smell.{Finding, Helpers}

  @broadcast_functions [
    :broadcast,
    :broadcast!,
    :broadcast_from,
    :broadcast_from!,
    :local_broadcast,
    :local_broadcast_from
  ]

  # A refetch call must read data or be unclassified; pure helpers, writes,
  # logging, and sends that receive the id are not refetches.
  @refetch_effects [:read, :unknown]

  @impl true
  def kinds, do: [:phoenix_pubsub_payload_refetch]

  @impl true
  def run(project) do
    functions = Helpers.function_defs(project)
    broadcasts = record_broadcasts_by_tag(functions, project.nodes)

    if broadcasts == %{} do
      []
    else
      functions
      |> Enum.filter(&(&1.meta[:name] == :handle_info and &1.meta[:arity] == 2))
      |> Enum.flat_map(&clauses/1)
      |> Enum.flat_map(&refetch_handler(&1, project.plugins))
      |> Enum.flat_map(&finding(&1, broadcasts))
      |> Enum.sort_by(&{&1.location, &1.message})
    end
  end

  # -- broadcasters ---------------------------------------------------------

  defp record_broadcasts_by_tag(functions, nodes) do
    {messages, wrappers} =
      functions
      |> Enum.flat_map(&broadcast_messages/1)
      |> Enum.split_with(&match?({:message, _node, _call}, &1))

    wrapper_messages = wrapper_messages(wrappers, nodes)

    (Enum.map(messages, fn {:message, node, call} -> {node, call} end) ++ wrapper_messages)
    |> Enum.flat_map(&record_message/1)
    |> Enum.group_by(fn {tag, _call} -> tag end, fn {_tag, call} -> call end)
  end

  defp broadcast_messages(function) do
    function
    |> clauses()
    |> Enum.flat_map(fn clause ->
      params = clause_param_names(clause, function.meta[:arity] || 0)

      clause
      |> IR.all_nodes()
      |> Enum.filter(&broadcast_call?/1)
      |> Enum.map(&broadcast_message(&1, params, function))
    end)
  end

  defp broadcast_message(call, params, function) do
    message = List.last(call.children)

    case message do
      %{type: :var, meta: %{name: name}} when is_map_key(params, name) ->
        {:wrapper,
         {function.meta[:module], function.meta[:name], function.meta[:arity],
          Map.fetch!(params, name)}, call}

      _message ->
        {:message, message, call}
    end
  end

  # One hop through a local wrapper such as
  # `defp broadcast(message), do: Phoenix.PubSub.broadcast(@pubsub, @topic, message)`.
  defp wrapper_messages([], _nodes), do: []

  defp wrapper_messages(wrappers, nodes) do
    targets =
      Map.new(wrappers, fn {:wrapper, {module, name, arity, index}, _call} ->
        {{module, name, arity}, index}
      end)

    Enum.flat_map(nodes, fn
      {_id, %{type: :call, meta: meta} = call} ->
        case Map.fetch(targets, {call_module(meta), meta[:function], meta[:arity]}) do
          {:ok, index} ->
            call.children |> Enum.slice(index, 1) |> Enum.map(&{&1, call})

          :error ->
            []
        end

      _entry ->
        []
    end)
  end

  defp call_module(%{module: nil, owner_module: owner}), do: owner
  defp call_module(%{module: module}), do: module
  defp call_module(_meta), do: nil

  defp broadcast_call?(%{type: :call, meta: %{function: function, module: module}})
       when function in @broadcast_functions do
    pubsub_module?(module)
  end

  defp broadcast_call?(_node), do: false

  defp pubsub_module?(Phoenix.PubSub), do: true

  defp pubsub_module?(module) when is_atom(module) and module != nil do
    module |> Atom.to_string() |> String.split(".") |> List.last() == "PubSub"
  end

  defp pubsub_module?(_module), do: false

  defp record_message(
         {%{type: :tuple, children: [%{type: :literal, meta: %{value: tag}}, payload]}, call}
       )
       when is_atom(tag) and not is_boolean(tag) and not is_nil(tag) do
    if record_payload?(payload), do: [{tag, call}], else: []
  end

  defp record_message(_message), do: []

  defp record_payload?(%{type: :var, meta: %{name: name}}), do: not id_name?(name)

  defp record_payload?(%{type: type, children: fields}) when type in [:map, :struct] do
    Enum.any?(fields, &(field_key(&1) not in [:id, nil]))
  end

  defp record_payload?(_payload), do: false

  defp field_key(%{type: :map_field, children: [%{type: :literal, meta: %{value: key}}, _value]}),
    do: key

  defp field_key(%{type: :map_field}), do: :dynamic
  defp field_key(_node), do: nil

  defp id_name?(name) when is_atom(name) do
    name = name |> Atom.to_string() |> String.trim_leading("_")
    name in ["id", "ids"] or String.ends_with?(name, ["_id", "_ids"])
  end

  defp id_name?(_name), do: true

  # -- receivers ------------------------------------------------------------

  defp refetch_handler(clause, plugins) do
    with [%{type: :tuple, children: [tag_node, payload]} | _rest] <- clause.children,
         %{type: :literal, meta: %{value: tag}} when is_atom(tag) <- tag_node,
         {:ok, id_var} <- id_only_pattern(payload),
         call when call != nil <- refetch_call(clause, id_var, plugins) do
      [%{tag: tag, call: call}]
    else
      _no_match -> []
    end
  end

  defp id_only_pattern(%{type: :match, children: [left, right]}) do
    cond do
      ignored_var?(right) -> id_only_pattern(left)
      ignored_var?(left) -> id_only_pattern(right)
      true -> :error
    end
  end

  defp id_only_pattern(%{type: type, children: [field]}) when type in [:map, :struct] do
    case field do
      %{type: :map_field, children: [%{type: :literal, meta: %{value: :id}}, value]} ->
        bound_var(value)

      _field ->
        :error
    end
  end

  defp id_only_pattern(_pattern), do: :error

  defp bound_var(%{type: :var, meta: %{name: name}}) when is_atom(name) do
    if underscored?(name), do: :error, else: {:ok, name}
  end

  defp bound_var(_node), do: :error

  defp ignored_var?(%{type: :var, meta: %{name: name}}) when is_atom(name), do: underscored?(name)
  defp ignored_var?(_node), do: false

  defp underscored?(name), do: name |> Atom.to_string() |> String.starts_with?("_")

  defp refetch_call(clause, id_var, plugins) do
    clause
    |> clause_body()
    |> IR.all_nodes()
    |> Enum.filter(
      &(&1.type == :call and passes_var?(&1, id_var) and
          Effects.classify(&1, plugins) in @refetch_effects)
    )
    |> Enum.min_by(&Helpers.source_sort_key/1, fn -> nil end)
  end

  defp passes_var?(call, name) do
    Enum.any?(call.children, fn
      %{type: :var, meta: %{name: ^name} = meta} -> meta[:binding_role] != :definition
      _child -> false
    end)
  end

  # -- shared ---------------------------------------------------------------

  defp clauses(function), do: Enum.filter(function.children, &(&1.type == :clause))

  defp clause_body(clause) do
    clause.children |> Enum.reject(&(&1.type == :guard)) |> Enum.drop(2)
  end

  defp clause_param_names(clause, arity) do
    clause.children
    |> Enum.reject(&(&1.type == :guard))
    |> Enum.take(arity)
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%{type: :var, meta: %{name: name}}, index} -> [{name, index}]
      _param -> []
    end)
    |> Map.new()
  end

  defp finding(handler, broadcasts) do
    case Map.get(broadcasts, handler.tag, []) do
      [] ->
        []

      calls ->
        locations =
          calls |> Enum.sort_by(&Helpers.source_sort_key/1) |> Enum.map(&Helpers.location/1)

        [
          Finding.new(
            kind: :phoenix_pubsub_payload_refetch,
            message:
              "handle_info/2 for {#{inspect(handler.tag)}, _} uses only the payload's id and queries again; " <>
                "the broadcaster at #{List.first(locations)} already sends the record. " <>
                "Use the payload, or broadcast only the id if the receiver must re-read " <>
                "(per-viewer visibility, fresh aggregates)",
            location: Helpers.location(handler.call),
            evidence: locations,
            confidence: :medium
          )
        ]
    end
  end
end
