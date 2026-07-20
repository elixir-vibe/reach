defmodule Reach.Evidence.Facade do
  @moduledoc "Collects module-level evidence about public APIs that only forward calls."

  alias Reach.Smell.Source

  defmodule Forwarder do
    @moduledoc false
    @derive JSON.Encoder
    defstruct [
      :function,
      :arity,
      :target_module,
      :target_function,
      :target_arity,
      :file,
      :line,
      :kind
    ]
  end

  defmodule Module do
    @moduledoc "Aggregated forwarding and boundary evidence for one module."
    @derive JSON.Encoder
    @type t :: %__MODULE__{}
    defstruct [
      :module,
      :file,
      :line,
      :public_function_count,
      :forwarder_count,
      :forwarder_ratio,
      :target_modules,
      :forwarders,
      :boundary_markers,
      :documented
    ]
  end

  @spec collect_project(Reach.Project.t()) :: [Module.t()]
  def collect_project(project) do
    module_names = module_names_by_location(project)

    project
    |> Source.module_files()
    |> Enum.flat_map(&collect_file(&1, module_names))
    |> Enum.sort_by(&{&1.file || "", &1.line || 0, &1.module || ""})
  end

  defp collect_file(file, module_names) do
    file
    |> Source.cached_ast()
    |> Reach.AST.modules_in_file()
    |> Enum.map(&module_evidence(&1, file, module_names))
    |> Enum.reject(&is_nil/1)
  rescue
    _error in [File.Error, SyntaxError, TokenMissingError] -> []
  end

  defp module_evidence({:defmodule, meta, [name, body]}, file, module_names) do
    statements = block_statements(keyword_value(body, :do))
    aliases = aliases(statements)
    entries = Enum.flat_map(statements, &public_entry(&1, aliases, file))
    public_functions = entries |> Enum.flat_map(& &1.signatures) |> MapSet.new()
    forwarders = complete_forwarders(entries, file)
    public_count = MapSet.size(public_functions)

    if public_count == 0 do
      nil
    else
      module = Map.get(module_names, {Path.expand(file), meta[:line]}, module_name_from_ast(name))

      %Module{
        module: module,
        file: file,
        line: meta[:line],
        public_function_count: public_count,
        forwarder_count: length(forwarders),
        forwarder_ratio: length(forwarders) / public_count,
        target_modules: forwarders |> Enum.map(& &1.target_module) |> Enum.uniq() |> Enum.sort(),
        forwarders: Enum.sort_by(forwarders, &{&1.line || 0, &1.function, &1.arity}),
        boundary_markers: boundary_markers(statements),
        documented: documented?(statements)
      }
    end
  end

  defp module_evidence(_node, _file, _module_names), do: nil

  defp public_entry({:defdelegate, meta, [head, opts]}, aliases, _file) do
    case function_head(head) do
      {:ok, name, params} ->
        signatures = function_signatures(name, params)
        target = opts |> keyword_value(:to) |> resolve_module(aliases)
        target_function = keyword_value(opts, :as) |> literal_atom() || name

        forwarder =
          if target do
            forwarder_template(
              signatures,
              target,
              target_function,
              length(params),
              meta[:line],
              :defdelegate
            )
          end

        [%{signatures: signatures, forwarder: forwarder}]

      :error ->
        []
    end
  end

  defp public_entry({:def, meta, [head, body]}, aliases, _file) do
    case function_head(head) do
      {:ok, name, params} ->
        signatures = function_signatures(name, params)

        forwarder =
          with {:ok, param_names} <- parameter_names(params),
               call when not is_nil(call) <- body |> keyword_value(:do) |> unwrap_block(),
               {:ok, target, target_function, args} <- remote_call(call, aliases),
               true <- argument_names(args) == {:ok, param_names} do
            forwarder_template(
              signatures,
              target,
              target_function,
              length(args),
              meta[:line],
              :def
            )
          else
            _not_forwarding -> nil
          end

        [%{signatures: signatures, forwarder: forwarder}]

      :error ->
        []
    end
  end

  defp public_entry({kind, _meta, [head | _body]}, _aliases, _file)
       when kind in [:defmacro, :defguard] do
    case function_head(head) do
      {:ok, name, params} -> [%{signatures: function_signatures(name, params), forwarder: nil}]
      :error -> []
    end
  end

  defp public_entry(_statement, _aliases, _file), do: []

  defp complete_forwarders(entries, file) do
    clause_counts =
      entries
      |> Enum.flat_map(& &1.signatures)
      |> Enum.frequencies()

    entries
    |> Enum.flat_map(fn
      %{forwarder: nil} -> []
      %{forwarder: forwarders} -> forwarders
    end)
    |> Enum.group_by(&{&1.function, &1.arity})
    |> Enum.flat_map(fn {signature, forwarders} ->
      targets = Enum.uniq_by(forwarders, &{&1.target_module, &1.target_function, &1.target_arity})

      if length(forwarders) == Map.fetch!(clause_counts, signature) and length(targets) == 1 do
        [%{hd(forwarders) | file: file}]
      else
        []
      end
    end)
  end

  defp forwarder_template(signatures, target, target_function, target_arity, line, kind) do
    Enum.map(signatures, fn {function, arity} ->
      %Forwarder{
        function: function,
        arity: arity,
        target_module: target,
        target_function: target_function,
        target_arity: target_arity,
        line: line,
        kind: kind
      }
    end)
  end

  defp function_head({:when, _meta, [head | _guards]}), do: function_head(head)

  defp function_head({name, _meta, params}) when is_atom(name) and is_list(params),
    do: {:ok, name, params}

  defp function_head(_head), do: :error

  defp function_signatures(name, params) do
    maximum_arity = length(params)
    minimum_arity = maximum_arity - Enum.count(params, &match?({:\\, _, _}, &1))
    Enum.map(minimum_arity..maximum_arity, &{name, &1})
  end

  defp parameter_names(params) do
    params
    |> Enum.map(&parameter_name/1)
    |> collect_names()
  end

  defp argument_names(args) do
    args
    |> Enum.map(&variable_name/1)
    |> collect_names()
  end

  defp collect_names(names) do
    if Enum.any?(names, &is_nil/1), do: :error, else: {:ok, names}
  end

  defp parameter_name({:\\, _meta, [parameter, _default]}), do: variable_name(parameter)
  defp parameter_name(parameter), do: variable_name(parameter)

  defp variable_name({name, _meta, context}) when is_atom(name) and is_atom(context), do: name
  defp variable_name(_node), do: nil

  defp remote_call({{:., _dot_meta, [module_ast, function]}, _meta, args}, aliases)
       when is_atom(function) and is_list(args) do
    case resolve_module(module_ast, aliases) do
      nil -> :error
      target -> {:ok, target, function, args}
    end
  end

  defp remote_call(_call, _aliases), do: :error

  defp documented?(statements) do
    Enum.any?(statements, fn
      {:@, _meta, [{:moduledoc, _attribute_meta, [value]}]} -> literal_value(value) != false
      _statement -> false
    end)
  end

  defp boundary_markers(statements) do
    statements
    |> Enum.flat_map(fn
      {:@, _meta, [{:behaviour, _attribute_meta, _value}]} -> [:behaviour]
      {:@, _meta, [{:deprecated, _attribute_meta, _value}]} -> [:deprecated]
      {:use, _meta, _args} -> [:use]
      _statement -> []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp aliases(statements) do
    Enum.reduce(statements, %{}, fn
      {:alias, _meta, [module_ast, opts]}, aliases ->
        case module_name_from_ast(module_ast) do
          nil -> put_unresolved_alias(aliases, module_ast, opts)
          module -> Map.put(aliases, alias_name(module, opts), module)
        end

      {:alias, _meta, [module_ast]}, aliases ->
        case module_name_from_ast(module_ast) do
          nil -> put_unresolved_alias(aliases, module_ast, [])
          module -> Map.put(aliases, module |> String.split(".") |> List.last(), module)
        end

      _statement, aliases ->
        aliases
    end)
  end

  defp alias_name(module, opts) do
    case opts |> keyword_value(:as) |> module_name_from_ast() do
      nil -> module |> String.split(".") |> List.last()
      name -> name
    end
  end

  defp resolve_module(module_ast, aliases) do
    case module_name_from_ast(module_ast) do
      nil -> nil
      module -> resolve_alias(module, aliases)
    end
  end

  defp resolve_alias(module, aliases) do
    [first | rest] = String.split(module, ".")

    case Map.fetch(aliases, first) do
      {:ok, :unresolved} -> nil
      {:ok, target} -> Enum.join([target | rest], ".")
      :error -> module
    end
  end

  defp put_unresolved_alias(aliases, module_ast, opts) do
    case unresolved_alias_name(module_ast, opts) do
      nil -> aliases
      name -> Map.put(aliases, name, :unresolved)
    end
  end

  defp unresolved_alias_name(module_ast, opts) do
    module_name_from_ast(keyword_value(opts, :as)) || syntactic_alias_name(module_ast)
  end

  defp syntactic_alias_name({:__aliases__, _meta, parts}) when is_list(parts) do
    case List.last(parts) do
      name when is_atom(name) -> to_string(name)
      _part -> nil
    end
  end

  defp syntactic_alias_name(_module_ast), do: nil

  defp module_name_from_ast({:__aliases__, _meta, parts}) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1), do: Enum.map_join(parts, ".", &to_string/1)
  end

  defp module_name_from_ast(module) when is_atom(module), do: inspect(module)
  defp module_name_from_ast(_module), do: nil

  defp literal_value({:__block__, _meta, [value]}), do: value
  defp literal_value(value), do: value

  defp literal_atom({:__block__, _meta, [value]}) when is_atom(value), do: value
  defp literal_atom(value) when is_atom(value), do: value
  defp literal_atom(_value), do: nil

  defp block_statements({:__block__, _meta, statements}) when is_list(statements), do: statements
  defp block_statements(nil), do: []
  defp block_statements(statement), do: [statement]

  defp unwrap_block({:__block__, _meta, [statement]}), do: statement
  defp unwrap_block(statement), do: statement

  defp keyword_value(entries, key) when is_list(entries) do
    Enum.find_value(entries, fn
      {{:__block__, _meta, [^key]}, value} -> value
      {^key, value} -> value
      _entry -> nil
    end)
  end

  defp keyword_value(_entries, _key), do: nil

  defp module_names_by_location(project) do
    for {_id, node} <- project.nodes,
        node.type == :module_def,
        node.source_span,
        into: %{} do
      key = {Path.expand(node.source_span.file), node.source_span.start_line}
      {key, inspect(node.meta[:name])}
    end
  end
end
