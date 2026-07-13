defmodule Reach.Plugins.SchemaFacts do
  @moduledoc false

  alias Reach.MacroFact

  def zoi(ast, file) do
    Enum.flat_map(Reach.AST.modules_in_file(ast), fn module_ast ->
      {module, body} = module_and_body(module_ast)

      collect(body, fn
        {{:., _dot_meta, [{:__aliases__, _, [:Zoi]}, function]}, meta, arguments}
        when function in [:object, :struct] and is_list(arguments) ->
          schema_fact(:zoi, module, function, List.last(arguments), meta, file)

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
          schema = resolve_attribute(schema, attributes)
          schema_fact(:nimble_options, module, function, schema, meta, file)

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

  defp schema_fact(framework, module, name, schema, meta, file) do
    fields = schema_fields(schema)

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
          data: %{fields: fields, key_representation: key_representation(fields)},
          confidence: :high
        }
      ]
    end
  end

  defp schema_fields(
         {{:., _dot_meta, [{:__aliases__, _, [:NimbleOptions]}, :new!]}, _meta, [schema]}
       ),
       do: schema_fields(schema)

  defp schema_fields({:%{}, _meta, entries}) when is_list(entries) do
    Enum.flat_map(entries, fn
      {key, _value} when is_atom(key) or is_binary(key) -> [{key, key_kind(key)}]
      _entry -> []
    end)
  end

  defp schema_fields(entries) when is_list(entries) do
    Enum.flat_map(entries, fn
      {key, _value} when is_atom(key) or is_binary(key) -> [{key, key_kind(key)}]
      _entry -> []
    end)
  end

  defp schema_fields(_schema), do: []

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
    do: Map.get(attributes, name)

  defp resolve_attribute(schema, _attributes), do: schema

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
