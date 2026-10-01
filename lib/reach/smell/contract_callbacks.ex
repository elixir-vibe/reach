defmodule Reach.Smell.ContractCallbacks do
  @moduledoc false

  # IR deliberately does not expand `use`. Explicit source declarations work without
  # dependencies; macro-injected behaviours need the compiled consumer's metadata.
  # Unknown contracts remain candidates instead of guessing callback names.
  def index(modules) do
    declarations =
      modules
      |> Enum.map(& &1.source_span.file)
      |> Enum.uniq()
      |> Enum.flat_map(&source_modules/1)
      |> Map.new()

    Map.new(modules, fn node ->
      name = node.meta[:name]
      declaration = Map.get(declarations, name, %{behaviours: [], uses?: false, callbacks: []})

      behaviours =
        declaration.behaviours ++
          if(declaration.uses?, do: compiled_behaviours(name, node.source_span.file), else: [])

      callbacks =
        behaviours
        |> Enum.uniq()
        |> Enum.flat_map(&behaviour_callbacks(&1, declarations))
        |> MapSet.new()

      {name, %{callbacks: callbacks, behaviours: MapSet.new(behaviours)}}
    end)
  end

  defp behaviour_callbacks(behaviour, declarations) do
    case Map.fetch(declarations, behaviour) do
      {:ok, contract} -> contract.callbacks
      :error -> compiled_callbacks(behaviour)
    end
  end

  def startup_facade?(function, contract, functions) do
    function.meta[:name] == :start_link and function.meta[:arity] == 1 and
      MapSet.member?(contract.behaviours, GenServer) and
      startup_result?(function, functions, MapSet.new(), MapSet.new([:__MODULE__]))
  end

  def functions(modules) do
    Map.new(
      for module <- modules,
          function <- module_functions(module),
          do: {{module.meta[:name], function.meta[:name], function.meta[:arity]}, function}
    )
  end

  def module_functions(%{type: :function_def} = function), do: [function]

  def module_functions(%{type: :module_def, children: children}),
    do: Enum.flat_map(children, &body_functions/1)

  defp body_functions(%{type: :block, children: children}),
    do: Enum.flat_map(children, &body_functions/1)

  defp body_functions(%{type: :function_def} = function), do: [function]
  defp body_functions(_node), do: []

  defp startup_result?(%{type: :function_def} = function, functions, visited, self_vars) do
    if MapSet.member?(visited, function.id) or function.children == [] do
      false
    else
      visited = MapSet.put(visited, function.id)
      Enum.all?(function.children, &startup_result?(&1, functions, visited, self_vars))
    end
  end

  defp startup_result?(%{type: :block, children: children}, functions, visited, self_vars) do
    not Enum.any?(Enum.drop(children, -1), &rebinds_self?(&1, self_vars)) and
      startup_result?(List.last(children), functions, visited, self_vars)
  end

  defp startup_result?(%{type: :clause, children: children}, functions, visited, self_vars) do
    startup_result?(List.last(children), functions, visited, self_vars)
  end

  defp startup_result?(%{type: :case, children: children}, functions, visited, self_vars) do
    clauses = Enum.filter(children, &(&1.type == :clause))
    clauses != [] and Enum.all?(clauses, &startup_result?(&1, functions, visited, self_vars))
  end

  defp startup_result?(
         %{
           type: :call,
           meta: %{module: GenServer, function: :start_link, arity: arity},
           children: [module | _]
         },
         _functions,
         _visited,
         self_vars
       )
       when arity in [2, 3],
       do: self_argument?(module, self_vars)

  defp startup_result?(
         %{
           type: :call,
           meta: %{module: module, function: name, arity: arity},
           children: arguments
         },
         functions,
         visited,
         self_vars
       ) do
    case Map.get(functions, {module, name, arity}) do
      nil ->
        false

      %{children: []} ->
        false

      target ->
        Enum.all?(target.children, fn clause ->
          forwarded = forwarded_self_vars(clause, arguments, arity, self_vars)

          MapSet.size(forwarded) > 0 and
            not MapSet.member?(visited, target.id) and
            startup_result?(clause, functions, MapSet.put(visited, target.id), forwarded)
        end)
    end
  end

  defp startup_result?(_node, _functions, _visited, _self_vars), do: false

  defp forwarded_self_vars(clause, arguments, arity, self_vars) do
    clause.children
    |> Enum.take(arity)
    |> Enum.zip(arguments)
    |> Enum.flat_map(fn
      {%{type: :var, meta: %{name: parameter}}, argument} ->
        if self_argument?(argument, self_vars), do: [parameter], else: []

      _ ->
        []
    end)
    |> MapSet.new()
  end

  defp self_argument?(%{type: :var, meta: %{name: name}}, self_vars),
    do: MapSet.member?(self_vars, name)

  defp self_argument?(_node, _self_vars), do: false

  defp rebinds_self?(%{type: :match, children: [pattern, _expression]}, self_vars),
    do: contains_self_var?(pattern, self_vars)

  defp rebinds_self?(%{type: :call, meta: %{function: :quote}}, _self_vars), do: false

  defp rebinds_self?(%{children: children}, self_vars),
    do: Enum.any?(children, &rebinds_self?(&1, self_vars))

  defp contains_self_var?(%{type: :var} = node, self_vars), do: self_argument?(node, self_vars)

  defp contains_self_var?(%{children: children}, self_vars),
    do: Enum.any?(children, &contains_self_var?(&1, self_vars))

  defp compiled_behaviours(module, file) do
    with {attributes, compile} <- compiled_metadata(module),
         source when not is_nil(source) <- compile[:source],
         true <- Path.expand(to_string(source)) == Path.expand(file) do
      attributes |> Keyword.get_values(:behaviour) |> List.flatten()
    else
      _ -> []
    end
  end

  # Reading an unloaded consumer's BEAM must not trigger its @on_load hook.
  defp compiled_metadata(module) when is_atom(module) do
    if function_exported?(module, :__info__, 1) do
      {module.__info__(:attributes), module.__info__(:compile)}
    else
      with path when is_list(path) and path != [] <- :code.which(module),
           {:ok, {^module, chunks}} <- :beam_lib.chunks(path, [:attributes, :compile_info]) do
        {chunks[:attributes], chunks[:compile_info]}
      else
        _ -> nil
      end
    end
  end

  defp compiled_metadata(_module), do: nil

  defp compiled_callbacks(module) when is_atom(module) do
    # Loaded code can have []/:cover_compiled origins despite a persisted BEAM.
    # Resolve that BEAM on the code path without loading or executing the module.
    with path when is_list(path) <- :code.where_is_file(Atom.to_charlist(module) ++ ~c".beam"),
         {:ok, {^module, chunks}} <- :beam_lib.chunks(path, [:attributes, :abstract_code]) do
      callbacks =
        chunks[:attributes]
        |> Enum.flat_map(fn
          {kind, values} when kind in [:callback, :macrocallback] ->
            Enum.flat_map(List.wrap(values), &callback_attribute_signature/1)

          _ ->
            []
        end)

      Enum.uniq(callbacks ++ abstract_callbacks(chunks[:abstract_code]))
    else
      _ -> []
    end
  end

  defp compiled_callbacks(_module), do: []

  defp callback_attribute_signature({{name, arity}, _types})
       when is_atom(name) and is_integer(arity) and arity >= 0,
       do: [{name, arity}]

  defp callback_attribute_signature(_attribute), do: []

  defp abstract_callbacks({:raw_abstract_v1, forms}) do
    Enum.flat_map(forms, fn
      {:attribute, _line, kind, attribute} when kind in [:callback, :macrocallback] ->
        callback_attribute_signature(attribute)

      {:function, _line, :behaviour_info, 1, clauses} ->
        Enum.flat_map(clauses, fn
          {:clause, _, [{:atom, _, :callbacks}], [], [body]} -> literal_callbacks(body)
          _ -> []
        end)

      _ ->
        []
    end)
  end

  defp abstract_callbacks(_unavailable), do: []

  defp literal_callbacks({nil, _line}), do: []

  defp literal_callbacks({:cons, _, {:tuple, _, [{:atom, _, name}, {:integer, _, arity}]}, tail})
       when arity >= 0,
       do: [{name, arity} | literal_callbacks(tail)]

  defp literal_callbacks(_expression), do: []

  defp source_modules(file) do
    with ".ex" <- Path.extname(file),
         {:ok, source} <- File.read(file),
         {:ok, ast} <- Code.string_to_quoted(source) do
      collect_modules(ast, nil)
    else
      _ -> []
    end
  end

  defp collect_modules({:__block__, _, forms}, parent),
    do: Enum.flat_map(forms, &collect_modules(&1, parent))

  defp collect_modules({:defmodule, _, [name_ast, [do: body]]}, parent) do
    name = module_name(name_ast, %{}, parent)
    forms = block_forms(body)
    aliases = aliases(forms, name)

    declaration = %{
      behaviours: Enum.flat_map(forms, &declared_behaviour(&1, aliases, name)),
      uses?: Enum.any?(forms, &match?({:use, _, _}, &1)),
      callbacks: Enum.flat_map(forms, &declared_callback/1)
    }

    [{name, declaration} | Enum.flat_map(forms, &collect_modules(&1, name))]
  end

  defp collect_modules(_ast, _parent), do: []

  defp block_forms({:__block__, _, forms}), do: forms
  defp block_forms(form), do: [form]

  defp aliases(forms, module) do
    Enum.reduce(forms, %{}, fn
      {:alias, _, [{{:., _, [prefix, :{}]}, _, suffixes}]}, acc ->
        group_aliases(module_name(prefix, acc, module), suffixes, acc)

      {:alias, _, [target | opts]}, acc ->
        full = module_name(target, acc, module)
        options = List.first(opts) || []

        short =
          if options[:as], do: module_name(options[:as], %{}, module), else: short_name(full)

        if full && short, do: Map.put(acc, short, full), else: acc

      _, acc ->
        acc
    end)
  end

  defp group_aliases(nil, _suffixes, aliases), do: aliases

  defp group_aliases(prefix, suffixes, aliases) do
    Enum.reduce(suffixes, aliases, fn
      {:__aliases__, _, parts}, aliases ->
        full = Module.concat([prefix | parts])
        Map.put(aliases, short_name(full), full)

      _, aliases ->
        aliases
    end)
  end

  defp short_name(module) when is_atom(module) and not is_nil(module),
    do: module |> Module.split() |> List.last() |> then(&Module.concat([&1]))

  defp short_name(_module), do: nil

  defp module_name({:__aliases__, _, parts}, aliases, _current) do
    if Enum.all?(parts, &is_atom/1) do
      [first | rest] = parts
      prefix = Map.get(aliases, Module.concat([first]), Module.concat([first]))
      Module.concat([prefix | rest])
    end
  end

  defp module_name({:__MODULE__, _, _}, _aliases, current), do: current
  defp module_name(module, _aliases, _current) when is_atom(module), do: module
  defp module_name(_ast, _aliases, _current), do: nil

  defp declared_behaviour({:@, _, [{:behaviour, _, [behaviour]}]}, aliases, module) do
    case module_name(behaviour, aliases, module) do
      nil -> []
      name -> [name]
    end
  end

  defp declared_behaviour(_form, _aliases, _module), do: []

  defp declared_callback({:@, _, [{kind, _, [spec]}]}) when kind in [:callback, :macrocallback],
    do: callback_signature(spec)

  defp declared_callback(_form), do: []

  defp callback_signature({:when, _, [spec | _guards]}), do: callback_signature(spec)

  defp callback_signature({:"::", _, [{name, _, args}, _return]}) when is_atom(name),
    do: [{name, length(args || [])}]

  defp callback_signature(_spec), do: []
end
