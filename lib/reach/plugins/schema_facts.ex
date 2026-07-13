defmodule Reach.Plugins.SchemaFacts do
  @moduledoc false

  alias Reach.MacroFact

  def zoi(ast, file) do
    Enum.flat_map(Reach.AST.modules_in_file(ast), fn module_ast ->
      {module, body} = module_and_body(module_ast)

      collect(body, fn
        {{:., _dot_meta, [{:__aliases__, _, [:Zoi]}, function]}, meta, arguments}
        when function in [:object, :struct] and is_list(arguments) ->
          schema_fact(
            :zoi,
            module,
            function,
            List.last(arguments),
            {:call, function, meta[:line]},
            meta,
            file
          )

        _node ->
          []
      end)
    end)
  end

  def nimble_options(ast, file) do
    Enum.flat_map(Reach.AST.modules_in_file(ast), fn module_ast ->
      {module, body} = module_and_body(module_ast)
      attributes = module_attributes(body)

      collect(body, fn
        {{:., _dot_meta, [{:__aliases__, _, [:NimbleOptions]}, function]}, meta,
         [_options, schema | _]}
        when function in [:validate, :validate!] ->
          {schema, identity} = resolve_attribute(schema, attributes)
          schema_fact(:nimble_options, module, function, schema, identity, meta, file)

        _node ->
          []
      end)
    end)
  end

  defp collect(ast, callback) do
    {_ast, facts} =
      Macro.prewalk(ast, [], fn node, facts ->
        {node, callback.(node) ++ facts}
      end)

    Enum.reverse(facts)
  end

  defp schema_fact(framework, module, name, schema, identity, meta, file) do
    field_specs = schema_field_specs(schema, framework)
    fields = Enum.map(field_specs, &{&1.name, &1.key_representation})

    if fields == [] do
      []
    else
      [
        %MacroFact{
          kind: :schema_declaration,
          source: %{file: file, line: meta[:line], column: meta[:column]},
          owner_module: module,
          target: {module, name},
          generated?: false,
          framework: framework,
          name: name,
          arity: nil,
          call_module: framework_module(framework),
          nesting: [],
          data: %{
            schema_identity: {framework, module, identity},
            fields: fields,
            field_specs: field_specs,
            required_fields: required_fields(field_specs),
            defaults: defaults(field_specs),
            key_representation: key_representation(fields)
          },
          confidence: :high
        }
      ]
    end
  end

  defp schema_field_specs(
         {{:., _dot_meta, [{:__aliases__, _, [:NimbleOptions]}, :new!]}, _meta, [schema]},
         :nimble_options
       ),
       do: schema_field_specs(schema, :nimble_options)

  defp schema_field_specs({:%{}, _meta, entries}, :zoi) when is_list(entries) do
    field_specs(entries, &zoi_field_spec/2)
  end

  defp schema_field_specs(entries, :nimble_options) when is_list(entries) do
    field_specs(entries, &nimble_field_spec/2)
  end

  defp schema_field_specs(_schema, _framework), do: []

  defp field_specs(entries, builder) do
    Enum.flat_map(entries, fn
      {key, value} when is_atom(key) or is_binary(key) -> [builder.(key, value)]
      _entry -> []
    end)
  end

  defp zoi_field_spec(key, schema) do
    calls = remote_call_names(schema, Zoi)

    %{
      name: key,
      key_representation: key_kind(key),
      type: zoi_type(calls),
      required?: :required in calls,
      default: zoi_default(schema)
    }
  end

  defp nimble_field_spec(key, options) do
    %{
      name: key,
      key_representation: key_kind(key),
      type: keyword_literal(options, :type),
      required?: keyword_literal(options, :required) == true,
      default: keyword_value(options, :default)
    }
  end

  defp remote_call_names(ast, module) do
    {_ast, names} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, parts}, name]}, _, _args} = node, names ->
          if Module.concat(parts) == module, do: {node, [name | names]}, else: {node, names}

        node, names ->
          {node, names}
      end)

    names
  end

  defp zoi_type(calls) do
    Enum.find(calls, &(&1 not in [:required, :default, :optional, :nullable]))
  end

  defp zoi_default(ast) do
    {_ast, default} =
      Macro.prewalk(ast, :none, fn
        {{:., _, [{:__aliases__, _, [:Zoi]}, :default]}, _, [value]} = node, :none ->
          {node, literal(value)}

        node, default ->
          {node, default}
      end)

    default
  end

  defp keyword_literal(options, key) do
    case keyword_value(options, key) do
      :none -> nil
      value -> value
    end
  end

  defp keyword_value(options, key) when is_list(options) do
    case List.keyfind(options, key, 0) do
      {^key, value} -> literal(value)
      nil -> :none
    end
  end

  defp keyword_value(_options, _key), do: :none

  defp literal(value) when is_atom(value) or is_binary(value) or is_number(value), do: value
  defp literal(value) when is_list(value), do: value
  defp literal(_value), do: :dynamic

  defp required_fields(field_specs) do
    field_specs |> Enum.filter(& &1.required?) |> Enum.map(& &1.name)
  end

  defp defaults(field_specs) do
    field_specs
    |> Enum.reject(&(&1.default == :none))
    |> Map.new(&{&1.name, &1.default})
  end

  defp key_representation(fields) do
    fields
    |> Enum.map(&elem(&1, 1))
    |> Enum.uniq()
    |> case do
      [kind] -> kind
      _kinds -> :mixed
    end
  end

  defp key_kind(key) when is_atom(key), do: :atom
  defp key_kind(key) when is_binary(key), do: :string

  defp module_attributes(body) do
    body
    |> statements()
    |> Enum.flat_map(fn
      {:@, _meta, [{name, _name_meta, [value]}]} when is_atom(name) -> [{name, value}]
      _statement -> []
    end)
    |> Map.new()
  end

  defp resolve_attribute({:@, _meta, [{name, _name_meta, _args}]}, attributes),
    do: {Map.get(attributes, name), {:attribute, name}}

  defp resolve_attribute(schema, _attributes), do: {schema, :inline}

  defp module_and_body({:defmodule, _meta, [module_ast, body]}) do
    {module_name(module_ast), keyword_body(body)}
  end

  defp keyword_body(body) when is_list(body), do: Keyword.get(body, :do)
  defp keyword_body(body), do: body

  defp statements({:__block__, _meta, statements}), do: statements
  defp statements(nil), do: []
  defp statements(statement), do: [statement]

  defp module_name({:__aliases__, _meta, parts}), do: Module.concat(parts)
  defp module_name(module) when is_atom(module), do: module
  defp module_name(_module), do: nil

  defp framework_module(:zoi), do: Zoi
  defp framework_module(:nimble_options), do: NimbleOptions
end
