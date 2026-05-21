defmodule Reach.Evidence.CloneAnalysis.ExDNA do
  @moduledoc "ExDNA-backed clone detection provider."

  alias Reach.Effects
  alias Reach.Evidence.CloneAnalysis.Clone
  alias Reach.Evidence.CloneAnalysis.Fragment
  alias Reach.IR
  alias Reach.Project.Query

  def analyze(project, config) do
    if available?() do
      project
      |> source_paths()
      |> run_ex_dna(config)
      |> Enum.map(&to_clone(&1, project))
      |> Enum.reject(&(&1.fragments == []))
      |> Enum.take(config.max_clones)
    else
      []
    end
  end

  def available? do
    Code.ensure_loaded?(Module.concat([ExDNA]))
  end

  defp source_paths(project) do
    project.nodes
    |> Map.values()
    |> Enum.flat_map(fn node ->
      case node.source_span do
        %{file: file} when is_binary(file) -> [file]
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.filter(&File.regular?/1)
  end

  defp run_ex_dna([], _config), do: []

  defp run_ex_dna(paths, config) do
    ex_dna = Module.concat([ExDNA])

    report =
      ex_dna.analyze(
        paths: paths,
        min_mass: config.min_mass,
        min_similarity: config.min_similarity,
        reporters: []
      )

    report.clones
  rescue
    _ -> []
  end

  defp to_clone(ex_dna_clone, project) do
    Clone.new(
      type: Map.get(ex_dna_clone, :type),
      mass: Map.get(ex_dna_clone, :mass),
      similarity: Map.get(ex_dna_clone, :similarity),
      fragments: Enum.map(Map.get(ex_dna_clone, :fragments, []), &fragment(&1, project)),
      suggestion: Map.get(ex_dna_clone, :suggestion)
    )
  end

  defp fragment(ex_dna_fragment, project) do
    file = Map.get(ex_dna_fragment, :file)
    line = Map.get(ex_dna_fragment, :line)
    function = if file && line, do: Query.find_function_at_location(project, file, line)
    module = (function && function.meta[:module]) || module_at_location(project, file, line)

    Fragment.new(
      file: file,
      line: line,
      module: module,
      function: function && function.meta[:name],
      arity: function && function.meta[:arity],
      effects: function_effects(function),
      effect_sequence: effect_sequence(function),
      calls: calls(function),
      return_shapes: return_shapes(function),
      map_accesses: map_accesses(function),
      validation_calls: validation_calls(function),
      mass: Map.get(ex_dna_fragment, :mass)
    )
  end

  defp module_at_location(_project, nil, _line), do: nil

  defp module_at_location(project, file, line) do
    for(
      {_id, node} <- project.nodes,
      node.type == :module_def and node.source_span,
      file_matches?(node.source_span.file, file),
      node.source_span.start_line <= line,
      do: node
    )
    |> Enum.max_by(& &1.source_span.start_line, fn -> nil end)
    |> case do
      nil -> nil
      module -> module.meta[:name]
    end
  end

  defp file_matches?(left, right),
    do: left == right or Path.expand(left || "") == Path.expand(right || "")

  defp function_effects(nil), do: []

  defp function_effects(function) do
    function
    |> IR.all_nodes()
    |> Enum.map(&node_effect/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp effect_sequence(nil), do: []

  defp effect_sequence(function) do
    function
    |> IR.all_nodes()
    |> Enum.filter(&(&1.type == :call))
    |> Enum.map(fn node -> {node_effect(node), call_signature(node)} end)
    |> Enum.reject(fn {effect, _call} -> effect in [:pure, :unknown] end)
  end

  defp calls(nil), do: []

  defp calls(function) do
    function
    |> IR.all_nodes()
    |> Enum.filter(&(&1.type == :call))
    |> Enum.map(&call_signature/1)
    |> Enum.reject(&is_nil/1)
  end

  defp return_shapes(nil), do: []

  defp return_shapes(function) do
    function
    |> IR.all_nodes()
    |> Enum.flat_map(&return_shape/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp map_accesses(nil), do: []

  defp map_accesses(function) do
    function
    |> IR.all_nodes()
    |> Enum.flat_map(&map_access/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp validation_calls(nil), do: []

  defp validation_calls(function) do
    function
    |> calls()
    |> Enum.filter(&validation_call?/1)
  end

  defp node_effect(node), do: Effects.classify(node)

  defp call_signature(%{meta: meta}) do
    {Map.get(meta, :module), Map.get(meta, :function), Map.get(meta, :arity)}
  end

  defp return_shape(%{type: :tuple, children: [%{type: :literal, meta: %{value: tag}} | _]})
       when tag in [:ok, :error] do
    [tag]
  end

  defp return_shape(%{type: :literal, meta: %{value: nil}}), do: [nil]

  defp return_shape(%{type: :literal, meta: %{value: value}}) when is_boolean(value),
    do: [:boolean]

  defp return_shape(%{type: :map}), do: [:map]
  defp return_shape(%{type: :struct, meta: %{module: module}}), do: [{:struct, module}]
  defp return_shape(_node), do: []

  defp map_access(%{
         type: :call,
         meta: %{module: module, function: :get, arity: arity},
         children: children
       })
       when module in [Access, Map] and arity in [2, 3] do
    case children do
      [%{type: :var, meta: %{name: variable}}, %{type: :literal, meta: %{value: key}} | _]
      when is_atom(key) or is_binary(key) ->
        [{variable, key_name(key), key_type(key)}]

      _ ->
        []
    end
  end

  defp map_access(_node), do: []

  defp validation_call?({_module, function, _arity}) when is_atom(function) do
    function
    |> Atom.to_string()
    |> String.starts_with?("validate")
  end

  defp validation_call?(_call), do: false

  defp key_name(key) do
    if is_binary(key), do: key, else: Atom.to_string(key)
  end

  defp key_type(key) do
    if is_binary(key), do: :string, else: :atom
  end
end
