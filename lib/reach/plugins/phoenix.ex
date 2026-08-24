defmodule Reach.Plugins.Phoenix do
  @moduledoc "Plugin for Phoenix conn, LiveView, and channel semantics."
  @behaviour Reach.Plugin

  alias Reach.IR
  alias Reach.IR.Node
  alias Reach.MacroFact

  import Reach.Plugins.Helpers, only: [find_vars_in: 1]

  @impl true
  def inference_hints do
    %{
      deps: [:phoenix, :phoenix_html, :phoenix_live_view, :phoenix_pubsub],
      source: [
        "Phoenix.Router",
        "Phoenix.LiveView",
        "Phoenix.LiveComponent",
        "Phoenix.Component",
        "Phoenix.PubSub"
      ]
    }
  end

  @impl true
  def smell_checks do
    [
      Reach.Plugins.Phoenix.Smells.AssignAsyncCapturesSocket,
      Reach.Plugins.Phoenix.Smells.AssignNewRefreshedValue,
      Reach.Plugins.Phoenix.Smells.DisconnectedMountRepo,
      Reach.Plugins.Phoenix.Smells.PubSubSubscribeWithoutConnected
    ]
  end

  @assign_modules [nil, Phoenix.Component, Phoenix.LiveView]

  @pure_local [
    :assign,
    :assign_new,
    :push_event,
    :push_patch,
    :push_navigate,
    :put_flash,
    :redirect,
    :render,
    :json,
    :text,
    :html,
    :send_resp,
    :put_status,
    :put_resp_content_type,
    :put_resp_header,
    :halt,
    :put_layout,
    :put_root_layout,
    :put_view,
    :put_new_layout,
    :live_render,
    :live_component,
    :on_mount,
    :sigil_H,
    :sigil_p
  ]

  @compile_time_dsl [
    :attr,
    :slot,
    :embed_templates,
    :plug,
    :get,
    :post,
    :put,
    :delete,
    :patch,
    :pipe_through,
    :pipeline,
    :scope,
    :live,
    :resources,
    :forward
  ]

  @route_dsl [
    :get,
    :post,
    :put,
    :delete,
    :patch,
    :options,
    :connect,
    :trace,
    :resources,
    :forward,
    :live
  ]
  @router_scope_dsl [:scope, :pipeline, :pipe_through, :plug]
  @component_dsl [:attr, :slot, :embed_templates]
  @use_modules [Phoenix.Router, Phoenix.Component, Phoenix.LiveView, Phoenix.LiveComponent]

  @pure_remote_modules [Phoenix.Component, Phoenix.LiveView, Phoenix.Controller, Plug.Conn]

  # Functions that mutate process/conn state despite living in a module that
  # is otherwise treated as pure (rendering helpers).
  @impure_remote_functions [{Phoenix.Controller, :delete_csrf_token}]

  @pubsub_functions [
    :broadcast,
    :broadcast!,
    :broadcast_from,
    :broadcast_from!,
    :direct_broadcast,
    :direct_broadcast!,
    :local_broadcast,
    :local_broadcast_from,
    :subscribe,
    :unsubscribe
  ]

  @impl true
  def refine_macro_fact(%MacroFact{name: :use, target: module} = fact, _context)
      when module in @use_modules do
    %{
      fact
      | framework: :phoenix,
        kind: phoenix_use_kind(module),
        data: phoenix_use_data(module, fact.data),
        confidence: :high
    }
  end

  def refine_macro_fact(%MacroFact{name: name, call_module: nil} = fact, _context)
      when name in @component_dsl do
    %{fact | framework: :phoenix, kind: phoenix_component_kind(name), confidence: :high}
  end

  def refine_macro_fact(%MacroFact{name: name, call_module: nil} = fact, _context)
      when name in @route_dsl do
    %{
      fact
      | framework: :phoenix,
        kind: :phoenix_route,
        target: phoenix_route_target(fact),
        data: phoenix_route_data(fact),
        confidence: :high
    }
  end

  def refine_macro_fact(%MacroFact{name: name, call_module: nil} = fact, _context)
      when name in @router_scope_dsl do
    %{fact | framework: :phoenix, kind: :phoenix_router_dsl, confidence: :high}
  end

  def refine_macro_fact(_fact, _context), do: :unchanged

  defp phoenix_use_kind(Phoenix.Router), do: :phoenix_router_use
  defp phoenix_use_kind(Phoenix.Component), do: :phoenix_component_use
  defp phoenix_use_kind(Phoenix.LiveView), do: :phoenix_live_view_use
  defp phoenix_use_kind(Phoenix.LiveComponent), do: :phoenix_live_component_use

  defp phoenix_use_data(Phoenix.LiveView, data) do
    Map.put(data, :explained_callbacks, [
      {:mount, 3},
      {:handle_event, 3},
      {:handle_info, 2},
      {:handle_params, 3},
      {:handle_async, 3},
      {:render, 1}
    ])
  end

  defp phoenix_use_data(Phoenix.LiveComponent, data) do
    Map.put(data, :explained_callbacks, [
      {:mount, 1},
      {:update, 2},
      {:update_many, 1},
      {:handle_event, 3},
      {:handle_async, 3},
      {:render, 1}
    ])
  end

  defp phoenix_use_data(Phoenix.Component, data) do
    Map.put(data, :explained_callbacks, [{:update, 2}, {:render, 1}])
  end

  defp phoenix_use_data(_module, data), do: data

  defp phoenix_component_kind(:attr), do: :phoenix_component_attr
  defp phoenix_component_kind(:slot), do: :phoenix_component_slot
  defp phoenix_component_kind(:embed_templates), do: :phoenix_embed_templates

  defp phoenix_route_target(%MacroFact{name: :live, data: %{args: [_path, live_view | _]}} = fact) do
    %{live_view: expand_web_module_name(fact.owner_module, live_view)}
  end

  defp phoenix_route_target(
         %MacroFact{name: name, data: %{args: [_path, controller, action | _]}} = fact
       )
       when name in [:get, :post, :put, :delete, :patch, :options, :connect, :trace] do
    %{
      route: phoenix_route_method(name),
      action: %{
        module: expand_web_module_name(fact.owner_module, controller),
        function: trim_atom(action),
        arity: 2
      }
    }
  end

  defp phoenix_route_target(%MacroFact{name: name, data: %{args: [path | _]}}) do
    %{route: phoenix_route_method(name), path: trim_literal(path)}
  end

  defp phoenix_route_target(_fact), do: nil

  defp phoenix_route_data(%MacroFact{name: name, data: %{args: args}}) do
    %{method: phoenix_route_method(name), args: args}
  end

  defp phoenix_route_data(fact), do: fact.data

  defp phoenix_route_method(name)
       when name in [:get, :post, :put, :delete, :patch, :options, :connect, :trace], do: name

  defp phoenix_route_method(name), do: name

  defp expand_web_module_name(owner_module, module_string) do
    module_string = trim_alias(module_string)

    cond do
      module_string == "" ->
        nil

      String.starts_with?(module_string, "Elixir.") ->
        String.trim_leading(module_string, "Elixir.")

      owner_module_base(owner_module) ->
        Enum.join([owner_module_base(owner_module), module_string], ".")

      true ->
        module_string
    end
  end

  defp owner_module_base(module) when is_atom(module) do
    case module |> Module.split() |> Enum.drop(-1) do
      [] -> nil
      parts -> Enum.join(parts, ".")
    end
  end

  defp owner_module_base(_module), do: nil

  defp trim_alias(string) do
    string
    |> trim_literal()
    |> String.trim_leading("Elixir.")
  end

  defp trim_atom(":" <> atom), do: atom
  defp trim_atom(value), do: trim_literal(value)

  defp trim_literal(value) do
    value
    |> String.trim()
    |> String.trim("\"")
  end

  @impl true
  def classify_effect(%Node{type: :call, meta: %{kind: :local, function: fun}})
      when fun in @compile_time_dsl,
      do: :write

  def classify_effect(%Node{type: :call, meta: %{kind: :local, function: fun}})
      when fun in @pure_local,
      do: :pure

  def classify_effect(%Node{
        type: :call,
        meta: %{kind: :remote, module: Phoenix.PubSub, function: function}
      })
      when function in @pubsub_functions,
      do: :send

  # Side-effecting controller/conn functions that must not be treated as pure
  # even though their module is in @pure_remote_modules.
  def classify_effect(%Node{type: :call, meta: %{kind: :remote, module: mod, function: fun}})
      when {mod, fun} in @impure_remote_functions,
      do: :write

  def classify_effect(%Node{type: :call, meta: %{kind: :remote, module: mod}})
      when mod in @pure_remote_modules,
      do: :pure

  def classify_effect(%Node{type: :call, meta: %{kind: :remote, module: mod}})
      when is_atom(mod) and mod != nil do
    mod_str = Atom.to_string(mod)

    if String.ends_with?(mod_str, "Routes") or String.ends_with?(mod_str, ".VerifiedRoutes"),
      do: :pure
  end

  def classify_effect(_), do: nil

  @param_names [:params, :user_params, :body_params]

  @impl true
  def trace_pattern(pattern) when pattern in ["conn.params", "params"] do
    fn node ->
      node.type == :var and node.meta[:name] in @param_names
    end
  end

  def trace_pattern(_pattern), do: nil

  @impl true
  def expected_effect_boundary?(_module, function, arity) do
    {function, arity} in [
      {:mount, 3},
      {:handle_event, 3},
      {:handle_params, 3},
      {:handle_info, 2},
      {:handle_async, 3},
      {:update, 2},
      {:render, 1}
    ]
  end

  @impl true
  def behaviour_label(callbacks) do
    if :mount in callbacks and :render in callbacks, do: "LiveView"
  end

  @impl true
  def analyze(all_nodes, _opts) do
    conn_param_to_action_edges(all_nodes) ++
      action_fallback_edges(all_nodes) ++
      socket_assign_edges(all_nodes)
  end

  @impl true
  def analyze_project(_modules, all_nodes, _opts) do
    plug_chain_edges(all_nodes)
  end

  defp conn_param_to_action_edges(all_nodes) do
    func_defs = Enum.filter(all_nodes, &(&1.type == :function_def))

    Enum.flat_map(func_defs, fn func ->
      clauses = Enum.filter(func.children, &(&1.type == :clause))

      conn_params =
        clauses
        |> Enum.flat_map(fn clause ->
          clause.children
          |> Enum.take(func.meta[:arity] || 0)
          |> Enum.flat_map(&find_pattern_vars/1)
        end)
        |> Enum.filter(&(&1.meta[:name] in [:params, :user_params, :body_params]))

      for var <- conn_params do
        {var.id, func.id, :phoenix_params}
      end
    end)
  end

  defp action_fallback_edges(all_nodes) do
    fallbacks =
      Enum.filter(all_nodes, fn n ->
        n.type == :call and n.meta[:function] == :action_fallback
      end)

    case fallbacks do
      [] ->
        []

      [fallback | _] ->
        all_nodes
        |> Enum.filter(&(&1.type == :function_def))
        |> Enum.flat_map(&error_tuples_in/1)
        |> Enum.map(fn err -> {err.id, fallback.id, :phoenix_action_fallback} end)
    end
  end

  defp socket_assign_edges(all_nodes) do
    assigns =
      Enum.filter(all_nodes, fn n ->
        n.type == :call and n.meta[:function] == :assign and
          n.meta[:module] in @assign_modules
      end)

    for assign_call <- assigns,
        arg <- assign_call.children,
        var <- find_vars_in(arg) do
      {var.id, assign_call.id, :phoenix_assign}
    end
  end

  defp plug_chain_edges(all_nodes) do
    scope_blocks =
      Enum.filter(all_nodes, fn n ->
        n.type == :call and n.meta[:function] in [:scope, :pipeline]
      end)

    scope_blocks
    |> Enum.flat_map(fn scope ->
      scope_nodes = IR.all_nodes(scope)

      pipe_throughs =
        Enum.filter(scope_nodes, fn n ->
          n.type == :call and n.meta[:function] == :pipe_through
        end)

      routes =
        Enum.filter(scope_nodes, fn n ->
          n.type == :call and
            n.meta[:function] in [:get, :post, :put, :patch, :delete, :resources]
        end)

      for pt <- pipe_throughs, route <- routes do
        {pt.id, route.id, :phoenix_plug_chain}
      end
    end)
  end

  defp error_tuples_in(func) do
    func |> IR.all_nodes() |> Enum.filter(&error_tuple?/1)
  end

  defp error_tuple?(node) do
    node.type == :tuple and
      match?([%{type: :literal, meta: %{value: :error}} | _], node.children)
  end

  defp find_pattern_vars(node) do
    node
    |> IR.all_nodes()
    |> Enum.filter(fn n -> n.type == :var and n.meta[:binding_role] == :definition end)
  end
end
