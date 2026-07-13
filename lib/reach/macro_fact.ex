defmodule Reach.MacroFact do
  @moduledoc "Source-level facts for macro and DSL declarations."

  defstruct [
    :kind,
    :source,
    :owner_module,
    :target,
    :generated?,
    :framework,
    :name,
    :arity,
    :call_module,
    :nesting,
    :data,
    :confidence
  ]

  @type location :: %{
          optional(:file) => String.t(),
          optional(:line) => non_neg_integer(),
          optional(:column) => non_neg_integer() | nil
        }

  @type t :: %__MODULE__{
          kind: atom(),
          source: location() | nil,
          owner_module: module() | nil,
          target: term(),
          generated?: boolean(),
          framework: atom() | nil,
          name: atom() | nil,
          arity: non_neg_integer() | nil,
          call_module: module() | nil,
          nesting: [atom()],
          data: map(),
          confidence: atom() | nil
        }

  @family :macro_fact
  @kinds [
    :macro_dsl_declaration,
    :typespec_declaration,
    :schema_declaration,
    :phoenix_router_use,
    :phoenix_component_use,
    :phoenix_live_view_use,
    :phoenix_live_component_use,
    :phoenix_component_attr,
    :phoenix_component_slot,
    :phoenix_embed_templates,
    :phoenix_route,
    :phoenix_router_dsl,
    :ecto_schema_use,
    :ecto_migration_use,
    :ecto_schema,
    :ecto_schema_field,
    :ecto_migration_dsl,
    :ash_resource_use,
    :ash_domain_use,
    :ash_policy_authorizer_use,
    :ash_actions,
    :ash_action,
    :ash_attribute,
    :ash_code_interface,
    :ash_resource_dsl,
    :ash_state_machine_dsl
  ]

  @definition_forms [:def, :defp, :defmacro, :defmacrop]
  @module_forms [:defmodule, :defprotocol, :defimpl]
  @control_forms [:=, :->, :fn, :case, :cond, :if, :unless, :with, :for, :receive, :try]
  @non_declaration_calls [:@, :alias, :require, :import]

  def family, do: @family
  def kinds, do: @kinds

  @doc "Collects source-level macro/DSL declaration facts from quoted Elixir AST."
  @spec collect_ast(Macro.t(), keyword()) :: [t()]
  def collect_ast(ast, opts \\ []) do
    file = Keyword.get(opts, :file)
    plugins = Keyword.get(opts, :plugins, [])
    context = Keyword.get(opts, :context, %{})

    context = Map.put_new(context, :file, file)

    generic_facts =
      ast
      |> Reach.AST.modules_in_file()
      |> Enum.flat_map(&collect_module(&1, file))

    plugin_facts = Reach.Plugin.macro_facts(plugins, ast, context)
    refine_facts(generic_facts ++ plugin_facts, plugins, context)
  end

  @doc "Parses and collects macro/DSL facts from an Elixir source string."
  @spec collect_source(String.t(), keyword()) :: {:ok, [t()]} | {:error, term()}
  def collect_source(source, opts \\ []) do
    file = Keyword.get(opts, :file, "nofile")

    case Code.string_to_quoted(source,
           columns: true,
           token_metadata: true,
           emit_warnings: false,
           file: file
         ) do
      {:ok, ast} -> {:ok, collect_ast(ast, Keyword.put(opts, :file, file))}
      {:error, _reason} = error -> error
    end
  end

  @doc "Reads and collects macro/DSL facts from a source file."
  @spec collect_file(Path.t(), keyword()) :: {:ok, [t()]} | {:error, term()}
  def collect_file(path, opts \\ []) do
    with {:ok, source} <- File.read(path) do
      collect_source(source, Keyword.put(opts, :file, path))
    end
  end

  @doc "Collects macro/DSL facts from all source files in a project."
  @spec collect_project(map(), keyword()) :: [t()]
  def collect_project(project, opts \\ []) do
    plugins = Keyword.get(opts, :plugins, Map.get(project, :plugins, []))

    files = Reach.Source.project_files(project)
    aliases = local_use_aliases(files)

    files
    |> Enum.flat_map(fn file ->
      case collect_file(file, Keyword.put(opts, :plugins, plugins)) do
        {:ok, facts} -> facts
        {:error, _reason} -> []
      end
    end)
    |> Enum.map(&apply_local_use_alias(&1, aliases))
    |> refine_facts(plugins, %{})
    |> Enum.uniq_by(&dedupe_key/1)
  end

  def by_kind(facts, kind) when is_atom(kind), do: Enum.filter(facts, &(&1.kind == kind))
  def by_kind(facts, kinds) when is_list(kinds), do: Enum.filter(facts, &(&1.kind in kinds))

  def by_framework(facts, framework), do: Enum.filter(facts, &(&1.framework == framework))

  def by_owner(facts, owner_module), do: Enum.filter(facts, &(&1.owner_module == owner_module))

  def explained_callbacks(facts, owner_module) do
    facts
    |> by_owner(owner_module)
    |> Enum.filter(&high_confidence_framework_fact?/1)
    |> Enum.flat_map(fn fact -> Map.get(fact.data || %{}, :explained_callbacks, []) end)
    |> MapSet.new()
  end

  defp high_confidence_framework_fact?(%__MODULE__{confidence: :high, framework: framework})
       when not is_nil(framework),
       do: true

  defp high_confidence_framework_fact?(_fact), do: false

  def at_source(facts, %{file: file, line: line}) do
    Enum.filter(facts, fn fact ->
      fact.source[:file] == file and fact.source[:line] == line
    end)
  end

  def at_source(facts, %{line: line}) do
    Enum.filter(facts, fn fact -> fact.source[:line] == line end)
  end

  defp local_use_aliases(files) do
    files
    |> Enum.flat_map(fn file ->
      with {:ok, source} <- File.read(file),
           {:ok, ast} <- Code.string_to_quoted(source, emit_warnings: false) do
        collect_local_use_aliases(ast)
      else
        _error -> []
      end
    end)
    |> Map.new()
  end

  defp collect_local_use_aliases(ast) do
    ast
    |> Reach.AST.modules_in_file()
    |> Enum.flat_map(&local_use_aliases_in_module/1)
  end

  defp local_use_aliases_in_module({:defmodule, _meta, [module_ast, body]}) do
    module = module_name(module_ast)

    body
    |> module_body()
    |> statements()
    |> Enum.flat_map(&local_use_alias(module, &1))
  end

  defp local_use_alias(module, {kind, _meta, [head, body]}) when kind in [:def, :defp] do
    with {name, _meta, args} when is_atom(name) <- unwrap_head(head),
         true <- args in [[], nil],
         target when is_atom(target) <- quoted_use_target(body) do
      [{{module, Atom.to_string(name)}, {name, target}}]
    else
      _other -> []
    end
  end

  defp local_use_alias(_module, _statement), do: []

  defp unwrap_head({:when, _meta, [head | _guards]}), do: unwrap_head(head)
  defp unwrap_head(head), do: head

  defp quoted_use_target(body) do
    body
    |> body_value()
    |> find_quoted_use_target()
  end

  defp body_value([block]) when is_list(block), do: body_value(block)

  defp body_value(body) when is_list(body) do
    Keyword.get(body, :do) ||
      Enum.find_value(body, fn
        {{:__block__, _meta, [:do]}, value} -> value
        _entry -> nil
      end)
  end

  defp body_value(value), do: value

  defp find_quoted_use_target({:quote, _meta, args}) when is_list(args) do
    args
    |> body_value()
    |> find_use_target()
  end

  defp find_quoted_use_target(_body), do: nil

  defp find_use_target(ast) do
    {_ast, target} =
      Macro.prewalk(ast, nil, fn
        {:use, _meta, [module_ast | _args]} = node, nil ->
          {node, module_name(module_ast)}

        node, target ->
          {node, target}
      end)

    target
  end

  defp apply_local_use_alias(
         %__MODULE__{name: :use, target: module, data: %{args: [arg | _]}} = fact,
         aliases
       ) do
    alias_name = trim_alias_arg(arg)

    case Map.get(aliases, {module, alias_name}) do
      nil ->
        fact

      {alias_atom, target} ->
        %{
          fact
          | target: target,
            call_module: target,
            data: Map.put(fact.data, :resolved_from, {module, alias_atom})
        }
    end
  end

  defp apply_local_use_alias(fact, _aliases), do: fact

  defp trim_alias_arg(":" <> atom), do: atom
  defp trim_alias_arg(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp trim_alias_arg(_value), do: nil

  defp refine_facts(facts, [], _context), do: facts

  defp refine_facts(facts, plugins, context) do
    Enum.map(facts, &Reach.Plugin.refine_macro_fact(plugins, &1, context))
  end

  defp dedupe_key(fact) do
    {fact.kind, fact.source, fact.owner_module, fact.target, fact.name, fact.arity, fact.nesting}
  end

  defp collect_module({:defmodule, _meta, [module_ast, body]}, file) do
    module = module_name(module_ast)

    body
    |> module_body()
    |> statements()
    |> Enum.flat_map(&collect_declaration(&1, module, [], file))
  end

  defp module_body(body) when is_list(body) do
    Keyword.get(body, :do) ||
      Enum.find_value(body, fn
        {{:__block__, _meta, [:do]}, value} -> value
        _entry -> nil
      end)
  end

  defp statements({:__block__, _meta, statements}) when is_list(statements), do: statements
  defp statements(nil), do: []
  defp statements(statement), do: [statement]

  defp collect_declaration(
         {:@, attribute_meta, [{kind, _meta, [{:"::", _type_meta, [head, return_type]}]}]},
         module,
         nesting,
         file
       )
       when kind in [:spec, :callback] do
    case typespec_head(head) do
      {:ok, name, arguments} ->
        arity = length(arguments)

        broad_map_parameters =
          arguments
          |> Enum.with_index()
          |> Enum.filter(fn {argument, _index} -> broad_map_type?(argument) end)
          |> Enum.map(&elem(&1, 1))

        [
          %__MODULE__{
            kind: :typespec_declaration,
            source: location(attribute_meta, file),
            owner_module: module,
            target: {module, name, arity},
            generated?: false,
            framework: :elixir,
            name: name,
            arity: arity,
            call_module: nil,
            nesting: Enum.reverse(nesting),
            data: %{
              declaration_kind: kind,
              broad_map_parameters: broad_map_parameters,
              return_type: Macro.to_string(return_type)
            },
            confidence: :high
          }
        ]

      :error ->
        []
    end
  end

  defp collect_declaration({form, _meta, _args}, _module, _nesting, _file)
       when form in @definition_forms or form in @module_forms,
       do: []

  defp collect_declaration({form, _meta, _args}, _module, _nesting, _file)
       when form in @control_forms,
       do: []

  defp collect_declaration(node, module, nesting, file) do
    case declaration_call(node) do
      nil ->
        []

      declaration ->
        fact = new(declaration, module, nesting, file)

        child_facts =
          node
          |> declaration_body_statements()
          |> Enum.flat_map(&collect_declaration(&1, module, [declaration.name | nesting], file))

        [fact | child_facts]
    end
  end

  defp typespec_head({:when, _meta, [head | _constraints]}), do: typespec_head(head)

  defp typespec_head({name, _meta, arguments}) when is_atom(name) and is_list(arguments),
    do: {:ok, name, arguments}

  defp typespec_head(_head), do: :error

  defp broad_map_type?({:map, _meta, []}), do: true
  defp broad_map_type?(_type), do: false

  defp declaration_call({:use, meta, args}) when is_list(args) do
    {call_module, rest} = use_module_and_args(args)

    %{
      name: :use,
      arity: length(args),
      call_module: call_module,
      meta: meta,
      target: call_module,
      data: %{args: Enum.map(rest, &Macro.to_string/1)}
    }
  end

  defp declaration_call({name, _meta, _args}) when name in @non_declaration_calls, do: nil

  defp declaration_call({name, meta, args}) when is_atom(name) and is_list(args) do
    arity = call_arity(args)

    %{
      name: name,
      arity: arity,
      call_module: nil,
      meta: meta,
      target: {nil, name, arity},
      data: call_data(args)
    }
  end

  defp declaration_call({{:., meta, [module_ast, name]}, _call_meta, args})
       when is_atom(name) and is_list(args) do
    call_module = module_name(module_ast)
    arity = call_arity(args)

    %{
      name: name,
      arity: arity,
      call_module: call_module,
      meta: meta,
      target: {call_module, name, arity},
      data: call_data(args)
    }
  end

  defp declaration_call(_node), do: nil

  defp use_module_and_args([module_ast | args]), do: {module_name(module_ast), args}
  defp use_module_and_args([]), do: {nil, []}

  defp call_arity(args), do: args |> Enum.reject(&keyword_block?/1) |> length()

  defp call_data(args), do: %{args: Enum.map(args, &Macro.to_string/1)}

  defp keyword_block?(block) when is_list(block) do
    Keyword.keyword?(block) and Enum.any?(block, fn {key, _value} -> block_key?(key) end)
  end

  defp keyword_block?(_block), do: false

  defp declaration_body_statements({_name, _meta, args}) when is_list(args) do
    args
    |> Enum.flat_map(&body_from_arg/1)
    |> Enum.flat_map(&statements/1)
  end

  defp declaration_body_statements({{:., _meta, _parts}, _call_meta, args}) when is_list(args) do
    args
    |> Enum.flat_map(&body_from_arg/1)
    |> Enum.flat_map(&statements/1)
  end

  defp declaration_body_statements(_node), do: []

  defp body_from_arg(block) when is_list(block) do
    block
    |> Enum.filter(fn
      {key, _value} -> block_key?(key)
      _entry -> false
    end)
    |> Enum.map(fn {_key, value} -> value end)
  end

  defp body_from_arg(_arg), do: []

  defp block_key?(:do), do: true
  defp block_key?(:else), do: true
  defp block_key?({:__block__, _meta, [key]}) when key in [:do, :else], do: true
  defp block_key?(_key), do: false

  defp new(declaration, module, nesting, file) do
    %__MODULE__{
      kind: :macro_dsl_declaration,
      source: location(declaration.meta, file),
      owner_module: module,
      target: declaration.target,
      generated?: false,
      framework: nil,
      name: declaration.name,
      arity: declaration.arity,
      call_module: declaration.call_module,
      nesting: Enum.reverse(nesting),
      data: declaration.data,
      confidence: :low
    }
  end

  defp module_name({:__aliases__, _meta, parts}) do
    if Enum.all?(parts, &is_atom/1), do: Module.concat(parts)
  end

  defp module_name({:__block__, _meta, [value]}), do: module_name(value)
  defp module_name(atom) when is_atom(atom), do: atom
  defp module_name(_ast), do: nil

  defp location(meta, nil), do: location(meta, nil, false)
  defp location(meta, file), do: location(meta, file, true)

  defp location(meta, file, include_file?) do
    base = %{line: meta[:line] || 0, column: meta[:column]}
    if include_file?, do: Map.put(base, :file, file), else: base
  end
end
