defmodule Reach.Evidence.CloneAnalysis.ExDNA do
  @moduledoc "ExDNA-backed clone detection provider."

  alias Reach.Effects
  alias Reach.Evidence.CloneAnalysis.Clone
  alias Reach.Evidence.CloneAnalysis.Fragment
  alias Reach.IR
  alias Reach.Project.Query

  @elixir_extensions [".ex", ".exs"]

  def analyze(project, config) do
    if available?() do
      project
      |> source_paths()
      |> run_ex_dna(config)
      |> Enum.map(&to_clone(&1, project, %{}))
      |> Enum.reject(&(&1.fragments == []))
      |> Enum.take(config.max_clones)
    else
      []
    end
  end

  @doc "Finds clone families containing both project and direct-dependency fragments."
  def dependency_clones(project, config) do
    dependency_clones(project, config, dependency_paths(config.dep_paths_limit))
  end

  @doc false
  def dependency_clones(project, config, dependencies) do
    if available?() and config.include_deps do
      {paths, origins} = dependency_source_paths(project, dependencies, config.dep_paths_limit)

      paths
      |> run_ex_dna(config)
      |> Enum.map(&to_clone(&1, project, origins))
      |> Enum.filter(&cross_dependency_clone?/1)
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
    |> Enum.filter(&(elixir_file?(&1) and File.regular?(&1)))
  end

  defp dependency_source_paths(project, dependencies, limit) do
    project_entries = Enum.map(source_paths(project), &{&1, :project})

    dependency_entries =
      dependencies
      |> Enum.sort_by(fn {app, _path} -> app end)
      |> Enum.take(limit)
      |> Enum.flat_map(fn {app, path} ->
        path
        |> Path.join("lib/**/*.{ex,exs}")
        |> Path.wildcard()
        |> Enum.sort()
        |> Enum.map(&{&1, {:dependency, app}})
      end)

    entries = Enum.uniq_by(project_entries ++ dependency_entries, &Path.expand(elem(&1, 0)))
    paths = Enum.map(entries, &elem(&1, 0))
    origins = Map.new(entries, fn {path, origin} -> {Path.expand(path), origin} end)
    {paths, origins}
  end

  defp dependency_paths(limit) do
    direct_apps =
      Mix.Project.config()
      |> Keyword.get(:deps, [])
      |> Enum.flat_map(&dependency_app/1)
      |> MapSet.new()

    Mix.Project.deps_paths()
    |> Enum.filter(fn {app, _path} -> MapSet.member?(direct_apps, app) end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.take(limit)
  rescue
    _error in [ArgumentError, Mix.Error] -> []
  end

  defp dependency_app({app, _requirement}) when is_atom(app), do: [app]
  defp dependency_app({app, _requirement, _opts}) when is_atom(app), do: [app]
  defp dependency_app(_dependency), do: []

  defp run_ex_dna([], _config), do: []

  defp run_ex_dna(paths, config) do
    ex_dna = Module.concat([ExDNA])

    opts =
      [
        paths: paths,
        min_mass: config.min_mass,
        min_occurrences: config.min_occurrences,
        min_similarity: config.min_similarity,
        max_window_size: config.max_window_size,
        mass_tolerance: config.mass_tolerance,
        literal_mode: config.literal_mode,
        normalize_pipes: config.normalize_pipes,
        excluded_macros: config.excluded_macros,
        parse_timeout: config.parse_timeout,
        ignore: config.ignore,
        reporters: []
      ]
      |> maybe_apply_ignored_attributes(config)

    report = ex_dna.analyze(opts)
    report.clones
  rescue
    _error in [ArgumentError, File.Error, MatchError] -> []
  end

  defp maybe_apply_ignored_attributes(opts, %{ignored_attributes: nil}), do: opts

  defp maybe_apply_ignored_attributes(opts, %{ignored_attributes: ignored_attributes}) do
    Keyword.put(opts, :ignored_attributes, ignored_attributes)
  end

  defp elixir_file?(file) when is_binary(file), do: Path.extname(file) in @elixir_extensions
  defp elixir_file?(_file), do: false

  defp to_clone(ex_dna_clone, project, origins) do
    Clone.new(
      type: Map.get(ex_dna_clone, :type),
      mass: Map.get(ex_dna_clone, :mass),
      similarity: Map.get(ex_dna_clone, :similarity),
      fragments: Enum.map(Map.get(ex_dna_clone, :fragments, []), &fragment(&1, project, origins)),
      suggestion: Map.get(ex_dna_clone, :suggestion)
    )
  end

  defp fragment(ex_dna_fragment, project, origins) do
    file = Map.get(ex_dna_fragment, :file)
    line = Map.get(ex_dna_fragment, :line)
    {origin, dependency} = fragment_origin(file, origins)

    function =
      if origin == :project and is_binary(file) and is_integer(line),
        do: Query.find_function_at_location(project, file, line)

    module =
      if origin == :project,
        do: (function && function.meta[:module]) || module_at_location(project, file, line)

    Fragment.new(
      file: file,
      line: line,
      origin: origin,
      dependency: dependency,
      module: module,
      function: function && function.meta[:name],
      arity: function && function.meta[:arity],
      effects: function_effects(function, project.plugins),
      effect_sequence: effect_sequence(function, project.plugins),
      calls: calls(function),
      return_shapes: return_shapes(function),
      map_accesses: map_accesses(function),
      validation_calls: validation_calls(function),
      mass: Map.get(ex_dna_fragment, :mass),
      whole_function: whole_function_fragment?(Map.get(ex_dna_fragment, :ast), function)
    )
  end

  defp whole_function_fragment?({kind, _meta, [head | _body]}, function)
       when kind in [:def, :defp] and not is_nil(function) do
    case definition_signature(head) do
      {name, arity} ->
        name == function.meta[:name] and arity == function.meta[:arity] and
          single_clause?(function)

      nil ->
        false
    end
  end

  defp whole_function_fragment?(_ast, _function), do: false

  defp definition_signature({:when, _meta, [head | _guards]}), do: definition_signature(head)

  defp definition_signature({name, _meta, args}) when is_atom(name) and is_list(args),
    do: {name, length(args)}

  defp definition_signature(_head), do: nil

  defp single_clause?(function) do
    Enum.count(function.children, &(&1.type == :clause)) <= 1
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

  defp fragment_origin(file, origins) when is_binary(file) do
    case Map.get(origins, Path.expand(file), :project) do
      {:dependency, dependency} -> {:dependency, dependency}
      :project -> {:project, nil}
    end
  end

  defp fragment_origin(_file, _origins), do: {:project, nil}

  defp cross_dependency_clone?(clone) do
    Enum.any?(clone.fragments, &(&1.origin == :project)) and
      Enum.any?(clone.fragments, &(&1.origin == :dependency))
  end

  defp function_effects(nil, _plugins), do: []

  defp function_effects(function, plugins) do
    function
    |> IR.all_nodes()
    |> Enum.map(&node_effect(&1, plugins))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp effect_sequence(nil, _plugins), do: []

  defp effect_sequence(function, plugins) do
    function
    |> IR.all_nodes()
    |> Enum.filter(&(&1.type == :call))
    |> Enum.map(fn node -> {node_effect(node, plugins), call_signature(node)} end)
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

  defp node_effect(node, plugins), do: Effects.classify(node, plugins)

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
