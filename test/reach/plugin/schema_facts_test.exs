defmodule Reach.Plugin.SchemaFactsTest do
  use ExUnit.Case, async: true

  alias Reach.MacroFact

  test "Zoi plugin extracts object schema fields" do
    source = """
    defmodule Contract do
      def schema do
        Zoi.object(%{
          name: Zoi.string() |> Zoi.required(),
          count: Zoi.integer() |> Zoi.default(0)
        })
      end
    end
    """

    assert {:ok,
            [
              %MacroFact{
                kind: :schema_declaration,
                framework: :zoi,
                owner_module: Contract,
                data: %{
                  fields: [name: :atom, count: :atom],
                  field_specs: [
                    %{name: :name, type: :string, required?: true, default: :none},
                    %{name: :count, type: :integer, required?: false, default: 0}
                  ],
                  required_fields: [:name],
                  defaults: %{count: 0},
                  key_representation: :atom
                }
              }
            ]} = MacroFact.collect_source(source, plugins: [Reach.Plugins.Zoi])
  end

  test "Zoi plugin connects parsed values to schema declarations" do
    source = """
    defmodule Contract do
      @schema Zoi.object(%{name: Zoi.string() |> Zoi.required()})
      def validate(input), do: Zoi.parse(@schema, input)
    end
    """

    assert {:ok, facts} = MacroFact.collect_source(source, plugins: [Reach.Plugins.Zoi])

    assert Enum.any?(facts, fn
             %MacroFact{
               framework: :zoi,
               name: :parse,
               data: %{
                 schema_identity: {:zoi, Contract, {:attribute, :schema}},
                 usage: %{function: {Contract, :validate, 1}, input: :input},
                 required_fields: [:name]
               }
             } ->
               true

             _fact ->
               false
           end)
  end

  test "NimbleOptions plugin resolves module attribute schemas" do
    source = """
    defmodule Contract do
      @schema [
        name: [type: :string, required: true],
        count: [type: :integer, default: 0]
      ]
      def validate(options), do: NimbleOptions.validate(options, @schema)
    end
    """

    assert {:ok, facts} =
             MacroFact.collect_source(source, plugins: [Reach.Plugins.NimbleOptions])

    assert Enum.any?(facts, fn
             %MacroFact{
               kind: :schema_declaration,
               framework: :nimble_options,
               owner_module: Contract,
               data: %{
                 schema_identity: {:nimble_options, Contract, {:attribute, :schema}},
                 usage: %{function: {Contract, :validate, 1}, input: :options},
                 fields: [name: :atom, count: :atom],
                 field_specs: [
                   %{name: :name, type: :string, required?: true, default: :none},
                   %{name: :count, type: :integer, required?: false, default: 0}
                 ],
                 required_fields: [:name],
                 defaults: %{count: 0},
                 key_representation: :atom
               }
             } ->
               true

             _fact ->
               false
           end)
  end

  test "schema plugins stay inactive when not configured" do
    source = """
    defmodule Contract do
      def schema, do: Zoi.object(%{name: Zoi.string()})
    end
    """

    assert {:ok, []} = MacroFact.collect_source(source, plugins: [])
  end
end
