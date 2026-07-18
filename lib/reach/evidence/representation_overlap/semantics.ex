defmodule Reach.Evidence.RepresentationOverlap.Semantics do
  @moduledoc false

  @presentation_module_segments ~w(
    adapter adapters converter exporter integration integrations introspect ir json merger normalizer
    persistence presentation presenter publisher registry renderer reporter schema schemas sender serializer
    storage thrift transformer transformers transport view web
  )
  @presentation_function_segments ~w(
    attrs camel cast classify convert describe detailed dump encode external format json map metadata
    normalise normalize parse payload project render safe serialize snake summarize summary unwrap
  )
  @boundary_variable_names ~w(attrs meta metadata optional_params params payload request row)
  @boundary_call_functions [:cmd]
  @constructor_functions [:build, :from_map, :from_map!, :new, :new!]
  @map_conversion_functions [
    :as_map,
    :from_map,
    :from_map!,
    :serialize,
    :to_external,
    :to_map,
    :unwrap
  ]

  @spec presentation_module?(module()) :: boolean()
  def presentation_module?(module) when is_atom(module) do
    if elixir_module?(module) do
      module
      |> Module.split()
      |> Enum.flat_map(&module_segments/1)
      |> Enum.any?(&(&1 in @presentation_module_segments))
    else
      false
    end
  end

  @spec presentation_function?(atom()) :: boolean()
  def presentation_function?(function) when is_atom(function) do
    function
    |> function_segments()
    |> Enum.any?(&(&1 in @presentation_function_segments))
  end

  @spec boundary_variable?(atom() | nil) :: boolean()
  def boundary_variable?(nil), do: false

  def boundary_variable?(name) when is_atom(name) do
    name = Atom.to_string(name)

    name in @boundary_variable_names or
      Enum.any?(@boundary_variable_names, &String.ends_with?(name, "_#{&1}"))
  end

  @spec boundary_call?(atom()) :: boolean()
  def boundary_call?(function), do: function in @boundary_call_functions

  @spec constructor_function?(atom()) :: boolean()
  def constructor_function?(function), do: function in @constructor_functions

  @spec map_conversion_function?(atom()) :: boolean()
  def map_conversion_function?(function), do: function in @map_conversion_functions

  @spec elixir_module?(atom()) :: boolean()
  def elixir_module?(module) when is_atom(module) do
    module |> Atom.to_string() |> String.starts_with?("Elixir.")
  end

  defp module_segments(segment) do
    segment
    |> Macro.underscore()
    |> String.split("_", trim: true)
  end

  defp function_segments(function) do
    function
    |> Atom.to_string()
    |> String.split("_", trim: true)
    |> Enum.map(&String.trim_trailing(String.trim_trailing(&1, "!"), "?"))
  end
end
