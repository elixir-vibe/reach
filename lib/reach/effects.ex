defmodule Reach.Effects do
  @moduledoc """
  Effect classification for IR nodes.

  Classifies each expression by its side effects — pure computations,
  IO, mutable state access, message passing, etc. Used by independence
  queries to determine whether reordering is safe.
  """

  alias Reach.IR.Node

  @type effect ::
          :pure
          | :read
          | :write
          | :io
          | :send
          | :receive
          | :exception
          | :nif
          | :unknown

  @doc """
  Classifies the effect of an IR node.
  """
  @compile_time_ops [
    :@,
    :use,
    :import,
    :alias,
    :require,
    :defstruct,
    :defdelegate,
    :doc,
    :moduledoc,
    :typedoc,
    :spec,
    :callback,
    :macrocallback,
    :impl,
    :type,
    :typep,
    :opaque,
    :behaviour,
    :"::",
    :defmacro,
    :defmacrop,
    :defguard,
    :defguardp,
    :__aliases__,
    :<<>>,
    :|,
    :\\,
    :when,
    :sigil_H,
    :sigil_p,
    :sigil_w,
    :t,
    :integer,
    :string,
    :boolean,
    :atom,
    :float,
    :map,
    :list,
    :keyword,
    :binary,
    :number,
    :pid,
    :term,
    :any,
    :none,
    :timeout,
    :mfa,
    :module,
    :arity,
    :pos_integer,
    :non_neg_integer,
    :neg_integer,
    :iodata,
    :iolist,
    :struct,
    :charlist,
    :byte,
    :char,
    :as_boolean,
    :struct!,
    :unquote,
    :quote
  ]

  @pure_node_types [
    :literal,
    :var,
    :pin,
    :tuple,
    :list,
    :cons,
    :map,
    :map_field,
    :struct,
    :match,
    :block,
    :guard,
    :clause,
    :case,
    :fn,
    :entry,
    :exit,
    :module_def,
    :function_def,
    :binary_op,
    :unary_op,
    :access,
    :dispatch,
    :generator,
    :filter,
    :comprehension
  ]

  @spec classify(Node.t(), [module()] | nil) :: effect()
  def classify(node, plugins \\ nil)

  def classify(%Node{type: type}, _plugins) when type in @pure_node_types, do: :pure

  def classify(%Node{type: :receive}, _plugins), do: :receive

  def classify(%Node{type: :call, meta: %{kind: :field_access}}, _plugins), do: :pure

  def classify(%Node{type: :call, meta: %{kind: :local, function: fun}}, _plugins)
      when fun in @compile_time_ops,
      do: :pure

  def classify(%Node{type: :call} = node, plugins) do
    plugins = resolve_plugins(plugins)

    case Reach.Plugin.classify_effect(plugins, node) do
      nil -> classify_call(node.meta[:module], node.meta[:function], node.meta[:arity], plugins)
      effect -> effect
    end
  end

  def classify(_node, _plugins), do: :unknown

  @doc """
  Returns true if the node is pure (no side effects).
  """
  @spec pure?(Node.t(), [module()] | nil) :: boolean()
  def pure?(node, plugins \\ nil), do: classify(node, plugins) == :pure

  @doc """
  Returns true if the node has the given effect.
  """
  @spec effectful?(Node.t(), effect(), [module()] | nil) :: boolean()
  def effectful?(node, effect, plugins \\ nil), do: classify(node, plugins) == effect

  @doc """
  Returns true if two effects conflict (reordering may change behavior).
  """
  @spec conflicting?(effect(), effect()) :: boolean()
  def conflicting?(:pure, _), do: false
  def conflicting?(_, :pure), do: false
  def conflicting?(:unknown, _), do: true
  def conflicting?(_, :unknown), do: true
  def conflicting?(:write, :write), do: true
  def conflicting?(:write, :read), do: true
  def conflicting?(:read, :write), do: true
  def conflicting?(:io, :io), do: true
  def conflicting?(:send, :send), do: true
  def conflicting?(:send, :receive), do: true
  def conflicting?(:receive, :send), do: true
  def conflicting?(:receive, :receive), do: true
  def conflicting?(_, _), do: false

  @doc """
  Infers effects for project-local functions by analyzing their call bodies.

  Walks all function definitions and classifies each based on the effects
  of its callees. Iterates until no new classifications are found (fixed-point).
  Results are cached in the ETS classify cache.
  """
  @spec infer_local_effects(%{Reach.IR.Node.id() => Reach.IR.Node.t()}, [module()] | nil) :: :ok
  def infer_local_effects(node_map, plugins \\ nil) do
    plugins = resolve_plugins(plugins)
    ensure_cache()

    all_nodes = Map.values(node_map)

    module_map = build_module_func_map(all_nodes)

    func_calls =
      all_nodes
      |> Enum.filter(&(&1.type == :function_def))
      |> Map.new(fn f ->
        calls =
          f.children
          |> collect_calls()
          |> Enum.reject(fn c ->
            c.meta[:kind] in [:field_access] or c.meta[:function] in @compile_time_ops
          end)

        {{f.meta[:module], f.meta[:name], f.meta[:arity]}, calls}
      end)

    do_infer(func_calls, module_map, plugins, 0)
  end

  defp build_module_func_map(all_nodes) do
    all_nodes
    |> Enum.filter(&(&1.type == :module_def))
    |> Enum.reduce(%{}, &add_module_functions/2)
  end

  defp add_module_functions(mod_def, acc) do
    mod_name = mod_def.meta[:name]

    mod_def.children
    |> Enum.flat_map(&extract_func_defs/1)
    |> Enum.reduce(acc, fn func, inner ->
      key = {nil, func.meta[:name], func.meta[:arity]}

      Map.update(inner, key, [mod_name], fn mods ->
        # credo:disable-for-next-line Credo.Check.Refactor.Nesting
        if mod_name in mods, do: mods, else: [mod_name | mods]
      end)
    end)
  end

  defp extract_func_defs(%{type: :function_def} = node), do: [node]

  defp extract_func_defs(%{type: :block, children: children}),
    do: Enum.filter(children, &(&1.type == :function_def))

  defp extract_func_defs(_), do: []

  defp collect_calls(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &collect_calls/1)

  defp collect_calls(%Reach.IR.Node{type: :call} = node) do
    [node | Enum.flat_map(node.children, &collect_calls/1)]
  end

  defp collect_calls(%Reach.IR.Node{children: children}) do
    Enum.flat_map(children, &collect_calls/1)
  end

  defp collect_calls(_), do: []

  defp do_infer(func_calls, module_map, plugins, prev_classified) do
    newly_classified =
      Enum.count(func_calls, &try_infer_function(&1, module_map, plugins))

    if newly_classified > 0 and newly_classified != prev_classified do
      do_infer(func_calls, module_map, plugins, newly_classified)
    else
      :ok
    end
  end

  defp try_infer_function({key, calls}, module_map, plugins) do
    if lookup_local_cache(key, plugins) != :miss do
      false
    else
      effects =
        calls
        |> Enum.map(&classify(&1, plugins))
        |> Enum.uniq()
        |> Enum.reject(&(&1 == :pure))

      infer_from_effects(key, effects, module_map, plugins)
    end
  end

  defp infer_from_effects(key, [], module_map, plugins) do
    cache_with_modules(key, :pure, module_map, plugins)
    true
  end

  defp infer_from_effects(key, effects, module_map, plugins) do
    if :unknown in effects do
      false
    else
      cache_with_modules(key, merge_effects(effects), module_map, plugins)
      true
    end
  end

  defp cache_with_modules({nil, name, arity} = key, effect, module_map, plugins) do
    put_local_cache(key, effect, plugins)

    case Map.get(module_map, key) do
      nil ->
        :ok

      modules ->
        Enum.each(modules, fn mod -> put_local_cache({mod, name, arity}, effect, plugins) end)
    end
  end

  defp cache_with_modules(key, effect, _module_map, plugins) do
    put_local_cache(key, effect, plugins)
  end

  defp merge_effects(effects) do
    cond do
      :write in effects -> :write
      :io in effects -> :io
      :send in effects -> :send
      :receive in effects -> :receive
      :exception in effects -> :exception
      :read in effects -> :read
      :nif in effects -> :nif
      true -> :unknown
    end
  end

  # --- Pure function database ---

  @pure_modules [
    Access,
    Calendar,
    Date,
    DateTime,
    Enum,
    Stream,
    Map,
    Keyword,
    List,
    Tuple,
    String,
    Atom,
    Integer,
    Float,
    MapSet,
    Range,
    Regex,
    URI,
    Path,
    Base,
    Bitwise,
    Macro,
    Version,
    :lists,
    :maps,
    :ordsets,
    :orddict,
    :sets,
    :gb_sets,
    :gb_trees,
    :dict,
    :proplists,
    :string,
    :binary,
    :math,
    :unicode,
    :filename,
    :re,
    NaiveDateTime,
    Time
  ]

  @pure_kernel_functions [
    :+,
    :-,
    :*,
    :/,
    :==,
    :!=,
    :===,
    :!==,
    :<,
    :>,
    :<=,
    :>=,
    :and,
    :or,
    :not,
    :!,
    :in,
    :..,
    :<>,
    :abs,
    :ceil,
    :floor,
    :round,
    :trunc,
    :div,
    :rem,
    :max,
    :min,
    :hd,
    :tl,
    :length,
    :elem,
    :tuple_size,
    :map_size,
    :is_atom,
    :is_binary,
    :is_bitstring,
    :is_boolean,
    :is_float,
    :is_function,
    :is_integer,
    :is_list,
    :is_map,
    :is_nil,
    :is_number,
    :is_pid,
    :is_port,
    :is_reference,
    :is_tuple,
    :is_map_key,
    :node,
    :self,
    :binary_part,
    :bit_size,
    :byte_size,
    :is_exception,
    :is_struct,
    :to_string,
    :to_charlist,
    :inspect
  ]

  @pure_erlang_functions [
    {:erlang, :abs, 1},
    {:erlang, :element, 2},
    {:erlang, :hd, 1},
    {:erlang, :length, 1},
    {:erlang, :map_size, 1},
    {:erlang, :max, 2},
    {:erlang, :min, 2},
    {:erlang, :node, 0},
    {:erlang, :self, 0},
    {:erlang, :tl, 1},
    {:erlang, :tuple_size, 1},
    {:erlang, :tuple_to_list, 1},
    {:erlang, :list_to_tuple, 1},
    {:erlang, :atom_to_binary, 1},
    {:erlang, :binary_to_atom, 1},
    {:erlang, :binary_to_atom, 2},
    {:erlang, :integer_to_binary, 1},
    {:erlang, :binary_to_integer, 1},
    {:erlang, :float_to_binary, 1},
    {:erlang, :binary_to_float, 1},
    {:erlang, :term_to_binary, 1},
    {:erlang, :binary_to_term, 1},
    {:erlang, :phash2, 1},
    {:erlang, :phash2, 2},
    {:erlang, :size, 1},
    {:erlang, :bit_size, 1},
    {:erlang, :byte_size, 1},
    {:erlang, :is_atom, 1},
    {:erlang, :is_binary, 1},
    {:erlang, :is_boolean, 1},
    {:erlang, :is_float, 1},
    {:erlang, :is_integer, 1},
    {:erlang, :is_list, 1},
    {:erlang, :is_map, 1},
    {:erlang, :is_number, 1},
    {:erlang, :is_pid, 1},
    {:erlang, :is_tuple, 1}
  ]

  # --- Call classification ---

  @classify_cache :reach_classify_cache

  @doc "Ensures the effect-classification ETS cache exists."
  def ensure_cache do
    if :ets.whereis(@classify_cache) == :undefined do
      :ets.new(@classify_cache, [:set, :public, :named_table, read_concurrency: true])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp classify_call(nil, function, _arity, _plugins) when function in @pure_kernel_functions,
    do: :pure

  defp classify_call(nil, function, _arity, _plugins) when function in [:raise, :throw, :exit],
    do: :exception

  defp classify_call(nil, :send, _arity, _plugins), do: :send

  defp classify_call(Kernel, function, _arity, _plugins) when function in @pure_kernel_functions,
    do: :pure

  defp classify_call(Kernel, function, _arity, _plugins) when function in [:raise, :throw, :exit],
    do: :exception

  defp classify_call(Kernel, :send, _arity, _plugins), do: :send

  # Shared ETS cache — survives across Task.async_stream workers.
  # Assumes no hot code reloads (CLI tool, not a server).
  defp classify_call(module, function, arity, plugins) do
    key = {module, function, arity}

    case lookup_local_cache(key, plugins) do
      {:ok, result} ->
        result

      :miss ->
        classify_builtin_call(module, function, arity)
    end
  end

  defp classify_builtin_call(module, function, arity) do
    key = {:builtin, module, function, arity}

    case lookup_cache(key) do
      {:ok, result} ->
        result

      :miss ->
        ensure_cache()
        result = do_classify_call(module, function, arity)
        put_cache(key, result)
        result
    end
  end

  defp resolve_plugins(nil) do
    case :persistent_term.get(:reach_effect_plugins, nil) do
      nil -> Reach.Plugin.detect()
      plugins -> plugins
    end
  end

  defp resolve_plugins(plugins) when is_list(plugins), do: plugins

  defp lookup_local_cache(key, plugins) do
    lookup_cache(local_cache_key(key, plugins))
  end

  defp put_local_cache(key, result, plugins) do
    put_cache(local_cache_key(key, plugins), result)
  end

  defp local_cache_key({module, function, arity}, plugins) do
    {:local, plugin_fingerprint(plugins), module, function, arity}
  end

  defp plugin_fingerprint(plugins) do
    plugins
    |> Enum.map(&inspect/1)
    |> Enum.sort()
    |> List.to_tuple()
  end

  defp lookup_cache(key) do
    case :ets.lookup(@classify_cache, key) do
      [{^key, result}] -> {:ok, result}
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp put_cache(key, result) do
    :ets.insert(@classify_cache, {key, result})
  rescue
    ArgumentError -> :ok
  end

  defp do_classify_call(module, function, arity) do
    classify_pure(module, function, arity) ||
      classify_io(module, function) ||
      classify_messaging(module, function) ||
      classify_state(module, function) ||
      classify_exception(module, function) ||
      classify_config(module, function) ||
      classify_from_spec(module, function, arity) ||
      :unknown
  end

  # Both Elixir (GenServer) and Erlang (:gen_server) atoms are listed
  # since the IR uses whichever form appears in the source code.
  @impure_modules [
    Process,
    Port,
    :erlang,
    :code,
    :ets,
    :os,
    :file,
    :gen_server,
    :gen_statem,
    :gen_event,
    :supervisor,
    :net_kernel,
    :global,
    :pg,
    :rpc,
    :public_key,
    :ssl,
    :gen_tcp,
    :gen_udp,
    :inet,
    System,
    Mix.Project,
    Mix,
    Agent,
    Code,
    Module,
    Node,
    Task,
    DynamicSupervisor,
    Registry,
    GenServer,
    Supervisor
  ]

  defp classify_from_spec(module, _function, _arity) when module in @impure_modules, do: nil

  defp classify_from_spec(module, function, arity) when is_atom(module) do
    case Code.Typespec.fetch_specs(module) do
      {:ok, specs} ->
        case List.keyfind(specs, {function, arity}, 0) do
          {_, clauses} ->
            infer_effect_from_spec(clauses) || classify_from_inferred(module, function, arity)

          nil ->
            nil
        end

      :error ->
        nil
    end
  rescue
    _error in [ArgumentError, ErlangError] -> nil
  end

  defp classify_from_spec(_, _, _), do: nil

  # Use Elixir 1.19+ inferred types from the ExCk BEAM chunk.
  # Returns :pure for functions returning data, nil otherwise.
  if Version.match?(System.version(), ">= 1.19.0") do
    defp classify_from_inferred(module, function, arity)
         when is_atom(module) and module not in @impure_modules do
      case read_inferred_sig(module, function, arity) do
        {:infer, _, clauses} when is_list(clauses) ->
          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
          if Enum.all?(clauses, fn {_args, ret} ->
               not returns_ok_atom?(ret) and concrete_data_type?(ret)
             end) do
            :pure
          end

        _ ->
          nil
      end
    rescue
      _error in [ArgumentError, ErlangError] -> nil
    end

    defp read_inferred_sig(module, function, arity) do
      with path when is_list(path) <- :code.which(module),
           {:ok, {_, [{~c"ExCk", chunk}]}} <- :beam_lib.chunks(path, [~c"ExCk"]),
           {_version, %{exports: exports}} <- :erlang.binary_to_term(chunk, [:safe]),
           {_, %{sig: sig}} <- List.keyfind(exports, {function, arity}, 0) do
        sig
      else
        _ -> nil
      end
    end

    defp returns_ok_atom?(%{dynamic: inner}), do: returns_ok_atom?(inner)
    defp returns_ok_atom?(%{atom: {:union, %{ok: []}}}), do: true
    defp returns_ok_atom?(_), do: false

    defp concrete_data_type?(%{dynamic: inner}), do: concrete_data_type?(inner)
    defp concrete_data_type?(%{list: _}), do: true
    defp concrete_data_type?(%{map: _}), do: true
    defp concrete_data_type?(%{tuple: _}), do: true
    defp concrete_data_type?(%{struct: _}), do: true
    defp concrete_data_type?(%{atom: _}), do: true
    defp concrete_data_type?(%{integer: _}), do: true
    defp concrete_data_type?(%{binary: _}), do: true
    defp concrete_data_type?(%{float: _}), do: true
    defp concrete_data_type?(%{range: _}), do: true
    defp concrete_data_type?(%{bitmap: _}), do: true

    defp concrete_data_type?(%{union: subtypes}) when is_map(subtypes),
      do: Enum.any?(subtypes, fn {_k, v} -> concrete_data_type?(v) end)

    defp concrete_data_type?(_), do: false
  else
    defp classify_from_inferred(_, _, _), do: nil
  end

  defp infer_effect_from_spec(clauses) do
    return_types = Enum.map(clauses, &extract_return_type/1)

    cond do
      Enum.all?(return_types, &ok_atom_type?/1) -> nil
      Enum.all?(return_types, &pure_return_type?/1) -> :pure
      true -> nil
    end
  end

  defp extract_return_type({:type, _, :fun, [{:type, _, :product, _}, return]}), do: return

  defp extract_return_type(
         {:type, _, :bounded_fun, [{:type, _, :fun, [{:type, _, :product, _}, return]}, _]}
       ),
       do: return

  defp extract_return_type(_), do: nil

  defp ok_atom_type?({:atom, _, :ok}), do: true
  defp ok_atom_type?(_), do: false

  defp pure_return_type?(nil), do: false
  defp pure_return_type?({:atom, _, :ok}), do: false

  defp pure_return_type?({:type, _, :tuple, [{:atom, _, :ok} | _]}), do: false

  defp pure_return_type?({:type, _, type, _})
       when type in [
              :integer,
              :non_neg_integer,
              :pos_integer,
              :float,
              :number,
              :binary,
              :bitstring,
              :boolean,
              :list,
              :map,
              :tuple,
              :atom,
              :module,
              :mfa,
              :arity,
              :node
            ],
       do: true

  defp pure_return_type?({:type, _, :union, subtypes}),
    do: Enum.all?(subtypes, &pure_return_type?/1)

  defp pure_return_type?({:type, _, :no_return, _}), do: true
  defp pure_return_type?({:type, _, :string, _}), do: true
  defp pure_return_type?({:type, _, :range, _}), do: true
  defp pure_return_type?({tag, _, _}) when tag in [:remote_type, :var, :atom], do: true
  defp pure_return_type?({:user_type, _, _, _}), do: true

  defp pure_return_type?(_), do: false

  @effectful_in_pure_modules [
    {Enum, :each, 2},
    {Enum, :each, 1},
    {:lists, :foreach, 2}
  ]

  defp classify_pure(module, function, arity) do
    cond do
      {module, function, arity} in @effectful_in_pure_modules -> :io
      pure_module?(module) or pure_function?(module, function, arity) -> :pure
      true -> nil
    end
  end

  defp classify_io(module, function) do
    if io_function?(module, function), do: :io
  end

  defp classify_messaging(module, function) do
    cond do
      send_function?(module, function) -> :send
      receive_function?(module, function) -> :receive
      true -> nil
    end
  end

  defp classify_config(Application, function)
       when function in [
              :get_env,
              :fetch_env,
              :fetch_env!,
              :get_all_env,
              :compile_env,
              :compile_env!
            ],
       do: :read

  defp classify_config(System, function)
       when function in [:get_env, :fetch_env, :fetch_env!],
       do: :read

  defp classify_config(System, function)
       when function in [
              :monotonic_time,
              :system_time,
              :os_time,
              :unique_integer,
              :schedulers,
              :schedulers_online,
              :otp_release,
              :version
            ],
       do: :read

  defp classify_config(Mix, :env), do: :read
  defp classify_config(Mix, :target), do: :read

  defp classify_config(Supervisor, :child_spec), do: :pure

  defp classify_config(GenServer, :start_link), do: :io
  defp classify_config(GenServer, :start), do: :io
  defp classify_config(Supervisor, :start_link), do: :io

  defp classify_config(_, _), do: nil

  # --- File I/O classification ---

  @file_read_fns [
    :read,
    :read!,
    :stat,
    :stat!,
    :exists?,
    :dir?,
    :regular?,
    :ls,
    :ls!,
    :cwd,
    :cwd!
  ]
  @file_write_fns [
    :write,
    :write!,
    :cp,
    :cp!,
    :cp_r,
    :cp_r!,
    :rm,
    :rm!,
    :rm_rf,
    :rm_rf!,
    :mkdir,
    :mkdir!,
    :mkdir_p,
    :mkdir_p!,
    :rename,
    :rename!,
    :touch,
    :touch!
  ]

  defp classify_file_io(File, function) do
    cond do
      function in @file_read_fns -> :read
      function in @file_write_fns -> :write
      true -> :io
    end
  end

  defp classify_file_io(:file, function) do
    cond do
      function in [:read_file, :read_file_info, :list_dir] -> :read
      function in [:write_file, :delete, :make_dir] -> :write
      true -> :io
    end
  end

  defp classify_file_io(_, _), do: nil

  defp classify_state(module, function) do
    classify_ets(module, function) ||
      classify_process_dict(module, function) ||
      classify_shared_mem(module, function) ||
      classify_file_io(module, function)
  end

  defp classify_ets(module, function) do
    cond do
      ets_write?(module, function) -> :write
      ets_read?(module, function) -> :read
      true -> nil
    end
  end

  defp classify_process_dict(module, function) do
    cond do
      process_dict_write?(module, function) -> :write
      process_dict_read?(module, function) -> :read
      true -> nil
    end
  end

  defp classify_shared_mem(module, function) do
    cond do
      atomics_write?(module, function) -> :write
      atomics_read?(module, function) -> :read
      persistent_term_write?(module, function) -> :write
      persistent_term_read?(module, function) -> :read
      true -> nil
    end
  end

  defp classify_exception(module, function) do
    if exception_function?(module, function), do: :exception
  end

  # --- Pure function database ---

  @doc "Returns modules whose functions are pure by default unless explicitly listed otherwise."
  def pure_modules, do: @pure_modules

  @doc "Returns true when a module/function/arity is classified as pure."
  def pure_call?(module, function, arity) do
    classify_pure(module, function, arity) == :pure
  end

  defp pure_module?(module), do: module in @pure_modules

  defp pure_function?(module, function, arity) do
    {module, function, arity} in @pure_erlang_functions
  end

  defp io_function?(IO, _), do: true
  defp io_function?(Logger, _), do: true
  defp io_function?(:io, _), do: true
  defp io_function?(_, _), do: false

  defp send_function?(_, :send), do: true
  defp send_function?(GenServer, :call), do: true
  defp send_function?(GenServer, :cast), do: true
  defp send_function?(GenServer, :reply), do: true
  defp send_function?(Process, :send_after), do: true
  defp send_function?(_, _), do: false

  defp receive_function?(GenServer, :handle_call), do: true
  defp receive_function?(GenServer, :handle_cast), do: true
  defp receive_function?(GenServer, :handle_info), do: true
  defp receive_function?(_, _), do: false

  defp ets_write?(:ets, f)
       when f in [
              :new,
              :insert,
              :insert_new,
              :delete,
              :delete_all,
              :delete_object,
              :update_counter,
              :update_element,
              :match_delete,
              :select_delete,
              :rename,
              :give_away,
              :setopts,
              :safe_fixtable
            ],
       do: true

  defp ets_write?(_, _), do: false

  defp ets_read?(:ets, f)
       when f in [
              :lookup,
              :lookup_element,
              :match,
              :match_object,
              :select,
              :member,
              :info,
              :tab2list,
              :first,
              :next,
              :last,
              :prev,
              :foldl,
              :foldr
            ],
       do: true

  defp ets_read?(_, _), do: false

  defp process_dict_write?(Process, :put), do: true
  defp process_dict_write?(Process, :delete), do: true
  defp process_dict_write?(_, _), do: false

  defp process_dict_read?(Process, :get), do: true
  defp process_dict_read?(Process, :get_keys), do: true
  defp process_dict_read?(_, _), do: false

  defp atomics_write?(mod, f)
       when mod in [:atomics, :counters] and f in [:put, :add, :add_get, :sub, :exchange],
       do: true

  defp atomics_write?(_, _), do: false

  defp atomics_read?(mod, f)
       when mod in [:atomics, :counters] and f in [:get, :info],
       do: true

  defp atomics_read?(:atomics, :new), do: false
  defp atomics_read?(:counters, :new), do: false
  defp atomics_read?(_, _), do: false

  defp persistent_term_write?(:persistent_term, f) when f in [:put, :erase], do: true
  defp persistent_term_write?(_, _), do: false

  defp persistent_term_read?(:persistent_term, f) when f in [:get, :get_keys], do: true
  defp persistent_term_read?(_, _), do: false

  defp exception_function?(Kernel, f) when f in [:raise, :throw, :exit], do: true
  defp exception_function?(:erlang, f) when f in [:error, :throw, :exit], do: true
  defp exception_function?(_, _), do: false
end
