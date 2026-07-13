defmodule Reach.Plugins.Ash do
  @moduledoc "Plugin for Ash framework action and resource semantics."
  @behaviour Reach.Plugin

  alias Reach.{AST, IR, MacroFact}
  alias Reach.IR.Node

  @impl true
  def inference_hints do
    %{deps: [:ash], source: ["Ash", "Ash.Resource", "Ash.Domain"]}
  end

  # --- Ash core CRUD (write) ---

  @ash_write_fns [
    :create,
    :create!,
    :update,
    :update!,
    :destroy,
    :destroy!,
    :bulk_create,
    :bulk_create!,
    :bulk_update,
    :bulk_update!,
    :bulk_destroy,
    :bulk_destroy!
  ]

  @ash_read_fns [
    :read,
    :read!,
    :read_one,
    :read_one!,
    :get,
    :get!,
    :exists?,
    :exists,
    :count,
    :count!,
    :sum,
    :sum!,
    :min,
    :min!,
    :max,
    :max!,
    :avg,
    :avg!,
    :first,
    :first!,
    :list,
    :list!,
    :aggregate,
    :aggregate!,
    :stream!,
    :page,
    :page!
  ]

  @ash_pure_fns [
    :can?,
    :can,
    :calculate,
    :calculate!
  ]

  @domain_read_prefixes [
    "get",
    "list",
    "read",
    "count",
    "exists",
    "aggregate"
  ]

  @domain_write_prefixes ["create", "update", "destroy", "delete"]

  @domain_module_suffixes [
    "Repo",
    "Controller",
    "View",
    "Live",
    "Component",
    "Socket",
    "Channel",
    "Endpoint",
    "Router",
    "Worker"
  ]

  # --- Ash.Changeset (all pure — builds intent, doesn't execute) ---

  @changeset_fns [
    :new,
    :for_create,
    :for_update,
    :for_destroy,
    :change_attribute,
    :change_attributes,
    :force_change_attribute,
    :force_change_attributes,
    :set_argument,
    :set_arguments,
    :put_context,
    :manage_relationship,
    :change_new_attribute,
    :clear_change,
    :delete_change,
    :get_attribute,
    :get_argument,
    :fetch_change,
    :fetch_change!,
    :get_change,
    :get_data,
    :apply_attributes,
    :set_context,
    :set_tenant,
    :before_action,
    :after_action,
    :before_transaction,
    :after_transaction,
    :around_action,
    :around_transaction,
    :add_error,
    :filter,
    :select,
    :ensure_selected,
    :deselect,
    :load
  ]

  # --- Ash.Query (all pure — builds query struct) ---

  @query_fns [
    :new,
    :for_read,
    :filter,
    :sort,
    :load,
    :select,
    :ensure_selected,
    :deselect,
    :offset,
    :limit,
    :set_tenant,
    :set_context,
    :put_context,
    :build,
    :before_action,
    :after_action,
    :distinct,
    :aggregate,
    :calculate,
    :lock,
    :set_domain,
    :page
  ]

  # --- Ash.Resource DSL macros (compile-time, pure) ---

  @resource_dsl [
    :attribute,
    :uuid_primary_key,
    :uuid_v7_primary_key,
    :integer_primary_key,
    :create_timestamp,
    :update_timestamp,
    :timestamps,
    :belongs_to,
    :has_many,
    :has_one,
    :many_to_many,
    :identities,
    :identity,
    :defaults,
    :default_accept,
    :argument,
    :validate,
    :change,
    :prepare,
    :accept,
    :policy,
    :bypass,
    :authorize_if,
    :forbid_if,
    :authorize_unless,
    :forbid_unless,
    :code_interface,
    :define,
    :define_calculation,
    :multitenancy,
    :pub_sub,
    :publish,
    :aggregates,
    :calculations,
    :calculate
  ]

  # --- AshPhoenix.Form ---

  @ash_phoenix_form_pure [
    :for_create,
    :for_update,
    :for_destroy,
    :for_read,
    :for_action,
    :validate,
    :params,
    :value,
    :errors,
    :changed?,
    :add_form,
    :remove_form,
    :update_form
  ]

  @ash_phoenix_form_write [:submit, :submit!]

  @ash_resource_block_dsl [
    :attributes,
    :relationships,
    :actions,
    :policies,
    :preparations,
    :validations,
    :changes
  ]

  @ash_action_dsl [:read, :create, :update, :destroy, :action]

  # --- AshStateMachine DSL (compile-time) ---

  @state_machine_dsl [
    :transitions,
    :transition,
    :initial_states,
    :default_initial_state,
    :extra_states,
    :deprecated_states
  ]

  @reinterpreted_block_dsl @ash_resource_block_dsl ++ @ash_action_dsl ++ @state_machine_dsl

  @impl true
  def reinterpreted_ast?(ast) do
    case AST.call(ast) do
      {nil, :expr, [_expression]} -> true
      {Ash.Expr, :expr, [_expression]} -> true
      {nil, name, args} when name in @reinterpreted_block_dsl -> block_call?(args)
      _other -> false
    end
  end

  defp block_call?(args), do: args |> List.last() |> AST.keyword?(:do)

  # --- Ash.Notifier ---

  @notifier_fns [:notify]

  # ============================================================
  # refine_macro_fact
  # ============================================================

  @impl true
  def refine_macro_fact(%MacroFact{name: :use, target: module} = fact, _context)
      when module in [Ash.Resource, Ash.Domain, Ash.Policy.Authorizer] do
    %{fact | framework: :ash, kind: ash_use_kind(module), confidence: :high}
  end

  def refine_macro_fact(%MacroFact{name: name} = fact, _context)
      when name in @resource_dsl or name in @ash_resource_block_dsl or name in @ash_action_dsl do
    %{fact | framework: :ash, kind: ash_resource_kind(name), confidence: :high}
  end

  def refine_macro_fact(%MacroFact{name: name} = fact, _context)
      when name in @state_machine_dsl do
    %{fact | framework: :ash, kind: :ash_state_machine_dsl, confidence: :high}
  end

  def refine_macro_fact(_fact, _context), do: :unchanged

  defp ash_use_kind(Ash.Resource), do: :ash_resource_use
  defp ash_use_kind(Ash.Domain), do: :ash_domain_use
  defp ash_use_kind(Ash.Policy.Authorizer), do: :ash_policy_authorizer_use

  defp ash_resource_kind(name) when name in [:code_interface, :define, :define_calculation],
    do: :ash_code_interface

  defp ash_resource_kind(:actions), do: :ash_actions

  defp ash_resource_kind(name) when name in @ash_resource_block_dsl,
    do: :ash_resource_dsl

  defp ash_resource_kind(name) when name in [:create, :read, :update, :destroy, :action],
    do: :ash_action

  defp ash_resource_kind(name) when name in [:attribute, :uuid_primary_key, :integer_primary_key],
    do: :ash_attribute

  defp ash_resource_kind(_name), do: :ash_resource_dsl

  # ============================================================
  # classify_effect
  # ============================================================

  @impl true

  # Ash core CRUD — write
  def classify_effect(%Node{type: :call, meta: %{kind: :remote, module: Ash, function: fun}})
      when fun in @ash_write_fns,
      do: :write

  # Ash core CRUD — read
  def classify_effect(%Node{type: :call, meta: %{kind: :remote, module: Ash, function: fun}})
      when fun in @ash_read_fns,
      do: :read

  # Ash core — pure
  def classify_effect(%Node{type: :call, meta: %{kind: :remote, module: Ash, function: fun}})
      when fun in @ash_pure_fns,
      do: :pure

  # Ash.run_action — generic actions can do anything, classify as :io
  def classify_effect(%Node{
        type: :call,
        meta: %{kind: :remote, module: Ash, function: fun}
      })
      when fun in [:run_action, :run_action!],
      do: :io

  # Ash.Changeset — all pure
  def classify_effect(%Node{
        type: :call,
        meta: %{kind: :remote, module: Ash.Changeset, function: fun}
      })
      when fun in @changeset_fns,
      do: :pure

  # Ash.Query — all pure
  def classify_effect(%Node{
        type: :call,
        meta: %{kind: :remote, module: Ash.Query, function: fun}
      })
      when fun in @query_fns,
      do: :pure

  # Ash.ActionInput — pure
  def classify_effect(%Node{
        type: :call,
        meta: %{kind: :remote, module: Ash.ActionInput, function: _fun}
      }),
      do: :pure

  # Resource DSL macros — pure (compile-time)
  def classify_effect(%Node{type: :call, meta: %{kind: :local, function: fun}})
      when fun in @resource_dsl,
      do: :pure

  # AshStateMachine DSL — pure
  def classify_effect(%Node{type: :call, meta: %{kind: :local, function: fun}})
      when fun in @state_machine_dsl,
      do: :pure

  # AshPhoenix.Form — pure builders
  def classify_effect(%Node{
        type: :call,
        meta: %{kind: :remote, module: AshPhoenix.Form, function: fun}
      })
      when fun in @ash_phoenix_form_pure,
      do: :pure

  # AshPhoenix.Form — submit (writes)
  def classify_effect(%Node{
        type: :call,
        meta: %{kind: :remote, module: AshPhoenix.Form, function: fun}
      })
      when fun in @ash_phoenix_form_write,
      do: :write

  # Ash.Notifier — send
  def classify_effect(%Node{
        type: :call,
        meta: %{kind: :remote, module: Ash.Notifier, function: fun}
      })
      when fun in @notifier_fns,
      do: :send

  # Domain module calls — detect code_interface generated functions
  def classify_effect(%Node{
        type: :call,
        meta: %{kind: :remote, module: mod, function: fun}
      })
      when is_atom(mod) and mod != nil do
    if domain_module?(mod), do: classify_domain_call(fun)
  end

  def classify_effect(_), do: nil

  # ============================================================
  # analyze (intra-module + cross-module edges from same source)
  # ============================================================

  @impl true
  def analyze(all_nodes, _opts) do
    mod_func_map = build_module_func_map(all_nodes)

    changeset_to_crud_edges(all_nodes) ++
      query_to_read_edges(all_nodes) ++
      action_input_to_run_edges(all_nodes) ++
      form_submit_edges(all_nodes) ++
      change_module_edges(all_nodes, mod_func_map) ++
      preparation_module_edges(all_nodes, mod_func_map) ++
      validation_module_edges(all_nodes, mod_func_map) ++
      code_interface_to_action_edges(all_nodes)
  end

  # ============================================================
  # analyze_project (cross-module edges across project)
  # ============================================================

  @impl true
  def analyze_project(_modules, all_nodes, _opts) do
    mod_func_map = build_module_func_map(all_nodes)

    change_module_edges(all_nodes, mod_func_map) ++
      preparation_module_edges(all_nodes, mod_func_map) ++
      validation_module_edges(all_nodes, mod_func_map) ++
      code_interface_to_action_edges(all_nodes)
  end

  # ============================================================
  # Intra-module edge builders
  # ============================================================

  # Ash.Changeset.for_create/for_update → Ash.create!/Ash.update!
  defp changeset_to_crud_edges(all_nodes) do
    func_defs = Enum.filter(all_nodes, &(&1.type == :function_def))

    Enum.flat_map(func_defs, fn func ->
      func_nodes = IR.all_nodes(func)

      changesets =
        Enum.filter(func_nodes, fn n ->
          n.type == :call and
            n.meta[:module] == Ash.Changeset and
            n.meta[:function] in [:for_create, :for_update, :for_destroy]
        end)

      writes =
        Enum.filter(func_nodes, fn n ->
          n.type == :call and n.meta[:module] == Ash and
            n.meta[:function] in @ash_write_fns
        end)

      for cs <- changesets, write <- writes do
        action = changeset_action_name(cs.meta[:function])
        {cs.id, write.id, {:ash_changeset_flow, action}}
      end
    end)
  end

  # Ash.Query.new/for_read → Ash.read!/Ash.get!
  defp query_to_read_edges(all_nodes) do
    func_defs = Enum.filter(all_nodes, &(&1.type == :function_def))

    Enum.flat_map(func_defs, fn func ->
      func_nodes = IR.all_nodes(func)

      queries =
        Enum.filter(func_nodes, fn n ->
          n.type == :call and n.meta[:module] == Ash.Query and
            n.meta[:function] in [:new, :for_read, :filter, :sort]
        end)

      reads =
        Enum.filter(func_nodes, fn n ->
          n.type == :call and n.meta[:module] == Ash and
            n.meta[:function] in @ash_read_fns
        end)

      for query <- queries, read <- reads do
        {query.id, read.id, :ash_query_flow}
      end
    end)
  end

  # Ash.ActionInput → Ash.run_action
  defp action_input_to_run_edges(all_nodes) do
    func_defs = Enum.filter(all_nodes, &(&1.type == :function_def))

    Enum.flat_map(func_defs, fn func ->
      func_nodes = IR.all_nodes(func)

      inputs =
        Enum.filter(func_nodes, fn n ->
          n.type == :call and n.meta[:module] == Ash.ActionInput
        end)

      runs =
        Enum.filter(func_nodes, fn n ->
          n.type == :call and n.meta[:module] == Ash and
            n.meta[:function] in [:run_action, :run_action!]
        end)

      for input <- inputs, run <- runs do
        {input.id, run.id, :ash_action_input_flow}
      end
    end)
  end

  # AshPhoenix.Form.for_create → AshPhoenix.Form.submit
  defp form_submit_edges(all_nodes) do
    func_defs = Enum.filter(all_nodes, &(&1.type == :function_def))

    Enum.flat_map(func_defs, fn func ->
      func_nodes = IR.all_nodes(func)

      forms =
        Enum.filter(func_nodes, fn n ->
          n.type == :call and n.meta[:module] == AshPhoenix.Form and
            n.meta[:function] in [:for_create, :for_update, :for_destroy, :for_action]
        end)

      submits =
        Enum.filter(func_nodes, fn n ->
          n.type == :call and n.meta[:module] == AshPhoenix.Form and
            n.meta[:function] in [:submit, :submit!]
        end)

      for form <- forms, submit <- submits do
        {form.id, submit.id, :ash_form_submit}
      end
    end)
  end

  # ============================================================
  # Cross-module edge builders
  # ============================================================

  # DSL `change MyModule` → MyModule.change/3
  defp change_module_edges(all_nodes, mod_func_map) do
    change_refs = find_dsl_module_refs(all_nodes, :change)

    Enum.flat_map(change_refs, fn {ref_node, target_mod} ->
      case find_func_in_module(mod_func_map, target_mod, :change, [3, 4]) do
        nil -> []
        impl -> [{ref_node.id, impl.id, :ash_change_dispatch}]
      end
    end)
  end

  # DSL `prepare MyModule` → MyModule.prepare/3
  defp preparation_module_edges(all_nodes, mod_func_map) do
    prep_refs = find_dsl_module_refs(all_nodes, :prepare)

    Enum.flat_map(prep_refs, fn {ref_node, target_mod} ->
      case find_func_in_module(mod_func_map, target_mod, :prepare, [3, 4]) do
        nil -> []
        impl -> [{ref_node.id, impl.id, :ash_preparation_dispatch}]
      end
    end)
  end

  # DSL `validate MyModule` → MyModule.validate/3
  defp validation_module_edges(all_nodes, mod_func_map) do
    val_refs = find_dsl_module_refs(all_nodes, :validate)

    Enum.flat_map(val_refs, fn {ref_node, target_mod} ->
      case find_func_in_module(mod_func_map, target_mod, :validate, [2, 3]) do
        nil -> []
        impl -> [{ref_node.id, impl.id, :ash_validation_dispatch}]
      end
    end)
  end

  # code_interface `define :func_name` in domain → resource action
  defp code_interface_to_action_edges(all_nodes) do
    defines =
      Enum.filter(all_nodes, fn n ->
        n.type == :call and n.meta[:function] == :define and
          n.meta[:kind] == :local
      end)

    action_defs =
      Enum.filter(all_nodes, fn n ->
        n.type == :call and n.meta[:function] in [:create, :read, :update, :destroy, :action] and
          n.meta[:kind] == :local
      end)

    for define <- defines,
        action_name <- extract_define_action(define),
        action <- action_defs,
        action_matches?(action, action_name) do
      {define.id, action.id, {:ash_code_interface, action_name}}
    end
  end

  # ============================================================
  # Helpers
  # ============================================================

  # Builds {module_name => [function_def_nodes]} from module_def nodes
  defp build_module_func_map(all_nodes) do
    all_nodes
    |> Enum.filter(&(&1.type == :module_def))
    |> Enum.flat_map(fn mod_def ->
      mod_name = mod_def.meta[:name]

      mod_def
      |> IR.all_nodes()
      |> Enum.filter(&(&1.type == :function_def))
      |> Enum.map(fn func -> {mod_name, func} end)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp find_func_in_module(mod_func_map, mod_name, func_name, arities) do
    mod_func_map
    |> Map.get(mod_name, [])
    |> Enum.find(fn func ->
      func.meta[:name] == func_name and func.meta[:arity] in arities
    end)
  end

  defp find_dsl_module_refs(all_nodes, dsl_function) do
    all_nodes
    |> Enum.filter(fn n ->
      n.type == :call and n.meta[:function] == dsl_function and
        n.meta[:kind] == :local
    end)
    |> Enum.flat_map(fn call ->
      call.children
      |> Enum.flat_map(&extract_module_refs/1)
      |> Enum.map(fn mod -> {call, mod} end)
    end)
  end

  defp extract_module_refs(%Node{type: :literal, meta: %{value: mod}})
       when is_atom(mod) and mod != nil and mod != true and mod != false do
    mod_str = Atom.to_string(mod)
    if String.starts_with?(mod_str, "Elixir."), do: [mod], else: []
  end

  defp extract_module_refs(%Node{
         type: :call,
         meta: %{function: :__aliases__},
         children: segments
       }) do
    segments
    |> Enum.reduce_while([], fn
      %Node{type: :literal, meta: %{value: seg}}, acc when is_atom(seg) ->
        {:cont, [seg | acc]}

      _segment, _acc ->
        {:halt, :invalid}
    end)
    |> case do
      :invalid -> []
      parts -> [Module.concat(Enum.reverse(parts))]
    end
  end

  # {MyModule, opts} tuple
  defp extract_module_refs(%Node{type: :tuple, children: [first | _]}) do
    extract_module_refs(first)
  end

  defp extract_module_refs(%Node{type: :call, meta: %{kind: :remote, module: mod}})
       when is_atom(mod) and mod != nil do
    [mod]
  end

  defp extract_module_refs(_), do: []

  defp extract_define_action(define_call) do
    case define_call.children do
      [%Node{type: :literal, meta: %{value: func_name}} | rest] when is_atom(func_name) ->
        action_name = extract_action_keyword(rest)
        [action_name || func_name]

      _ ->
        []
    end
  end

  defp extract_action_keyword(rest) do
    Enum.find_value(rest, fn
      %Node{type: :list, children: pairs} ->
        Enum.find_value(pairs, fn
          %Node{
            type: :tuple,
            children: [%Node{meta: %{value: :action}}, %Node{meta: %{value: v}}]
          } ->
            v

          _ ->
            nil
        end)

      _ ->
        nil
    end)
  end

  defp action_matches?(action_call, action_name) do
    match?([%Node{type: :literal, meta: %{value: ^action_name}} | _], action_call.children)
  end

  defp changeset_action_name(:for_create), do: :create
  defp changeset_action_name(:for_update), do: :update
  defp changeset_action_name(:for_destroy), do: :destroy
  defp changeset_action_name(_), do: :unknown

  defp domain_module?(mod) when is_atom(mod) do
    mod
    |> Atom.to_string()
    |> excluded_domain_module?()
    |> Kernel.not()
    |> Kernel.and(Code.ensure_loaded?(mod))
    |> Kernel.and(function_exported?(mod, :spark_dsl_config, 0))
  end

  defp excluded_domain_module?(mod_str) do
    Enum.any?(@domain_module_suffixes, &String.ends_with?(mod_str, &1))
  end

  defp classify_domain_call(fun) do
    fun_str = Atom.to_string(fun)

    cond do
      prefixed_with?(fun_str, @domain_write_prefixes) -> :write
      prefixed_with?(fun_str, @domain_read_prefixes) -> :read
      true -> nil
    end
  end

  defp prefixed_with?(value, prefixes) do
    Enum.any?(prefixes, &String.starts_with?(value, &1))
  end
end
