defmodule Reach.Plugins.SchemaFacts do
  @moduledoc false

  alias Reach.MacroFact

  def zoi(ast, file) do
    Enum.flat_map(Reach.AST.modules_in_file(ast), fn module_ast ->
      {module, body} = module_and_body(module_ast)

      attributes = module_attributes(body)

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

        {{:., _dot_meta, [{:__aliases__, _, [:Zoi]}, function]}, meta, [schema, input]} = node
        when function in [:parse, :parse!] ->
          {schema, identity} = resolve_attribute(schema, attributes)

          schema_fact(
            :zoi,
            module,
            function,
            zoi_schema(schema),
            identity,
            meta,
            file,
            usage(body, module, node, input)
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
         [options, schema | _]} = node
        when function in [:validate, :validate!] ->
          {schema, identity} = resolve_attribute(schema, attributes)

          schema_fact(
            :nimble_options,
            module,
            function,
            schema,
            identity,
            meta,
            file,
            usage(body, module, node, options)
          )

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
    schema_fact(framework, module, name, schema, identity, meta, file, nil)
  end

  defp schema_fact(framework, module, name, schema, identity, meta, file, usage) do
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
            usage: usage,
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

  defp zoi_schema({{:., _, [{:__aliases__, _, [:Zoi]}, function]}, _, arguments})
       when function in [:object, :struct] and is_list(arguments),
       do: List.last(arguments)

  defp zoi_schema(_schema), do: nil

  defp usage(body, module, call, input) do
    %{
      function: containing_function(body, module, call),
      input: input_variable(input)
    }
  end

  defp containing_function(body, module, target) do
    body
    |> statements()
    |> Enum.find_value(fn
      {kind, _meta, [head, definition]} when kind in [:def, :defp] ->
        if contains_ast?(definition, target), do: function_id(module, head)

      _statement ->
        nil
    end)
  end

  defp contains_ast?(ast, target) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        node, false -> {node, node == target}
        node, true -> {node, true}
      end)

    found?
  end

  defp function_id(module, {:when, _meta, [head | _guards]}), do: function_id(module, head)

  defp function_id(module, {name, _meta, arguments}) when is_atom(name) and is_list(arguments),
    do: {module, name, length(arguments)}

  defp function_id(_module, _head), do: nil

  defp input_variable({name, _meta, context}) when is_atom(name) and is_atom(context), do: name
  defp input_variable(_input), do: nil

  defp module_attributes(body) do
    body
    |> statements()
    |> Enum.flat_map(fn
      {:@, _meta, [{name, _name_meta, [value]}]} when is_atom(name) -> [{name, value}]
      _statement -> []
    end)
    |> Map.new()
  end

  defp resolve_attribute({:@, _meta, [{name, _name_meta, _args}]}, attributes) do
    {expand_schema_attributes(Map.get(attributes, name), attributes, MapSet.new([name])),
     {:attribute, name}}
  end

  defp resolve_attribute(schema, attributes) do
    {expand_schema_attributes(schema, attributes, MapSet.new()), :inline}
  end

  defp expand_schema_attributes(values, attributes, seen) when is_list(values) do
    Enum.flat_map(values, &expand_schema_entry(&1, attributes, seen))
  end

  defp expand_schema_attributes(value, _attributes, _seen), do: value

  defp expand_schema_entry(
         {:@, _meta, [{name, _name_meta, _args}]} = attribute,
         attributes,
         seen
       ) do
    if MapSet.member?(seen, name) do
      [attribute]
    else
      attributes
      |> Map.get(name)
      |> expand_schema_attributes(attributes, MapSet.put(seen, name))
      |> List.wrap()
    end
  end

  defp expand_schema_entry(value, _attributes, _seen), do: [value]

  defp module_and_body({:defmodule, _meta, [module_ast, body]}) do
    {module_name(module_ast), keyword_body(body)}
  end

  defp keyword_body(body) when is_list(body), do: Keyword.get(body, :do)
  defp keyword_body(body), do: body

  defp statements({:__block__, _meta, statements}), do: statements
  defp statements(nil), do: []
  defp statements(statement), do: [statement]

  defp module_name({:__aliases__, _meta, _parts} = module_ast) do
    case Reach.AST.module_name(module_ast) do
      {:ok, module} -> module
      :error -> nil
    end
  end

  defp module_name(module) when is_atom(module), do: module
  defp module_name(_module), do: nil

  defp framework_module(:zoi), do: Zoi
  defp framework_module(:nimble_options), do: NimbleOptions
end
