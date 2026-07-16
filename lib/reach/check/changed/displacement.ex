defmodule Reach.Check.Changed.Displacement do
  @moduledoc "Compares stable evidence identities across changed-code snapshots."

  alias Reach.Check.Changed.DisplacedFact
  alias Reach.Check.Changed.Range
  alias Reach.Check.Changed.SourceSnapshot
  alias Reach.Config
  alias Reach.Evidence.CloneAnalysis
  alias Reach.Evidence.MapContract
  alias Reach.IR.Helpers, as: IRHelpers
  alias Reach.Project

  @spec analyze(Project.t(), String.t(), map(), Config.t() | keyword(), keyword()) ::
          [DisplacedFact.t()]
  def analyze(project, base, changed_ranges, config, opts \\ []) do
    revision = SourceSnapshot.revision(base, opts)
    files = changed_source_files(changed_ranges)

    {old_sources, new_sources} = source_pairs(files, revision, opts)

    if map_size(old_sources) == 0 do
      []
    else
      compare_snapshots(
        project,
        changed_ranges,
        old_sources,
        new_sources,
        Config.normalize(config)
      )
    end
  end

  defp compare_snapshots(project, changed_ranges, old_sources, new_sources, config) do
    root =
      Path.join(
        System.tmp_dir!(),
        "reach-displacement-#{System.unique_integer([:positive, :monotonic])}"
      )

    try do
      old_snapshot = build_snapshot(Path.join(root, "old"), old_sources, project.plugins, config)
      new_snapshot = build_snapshot(Path.join(root, "new"), new_sources, project.plugins, config)
      displaced(old_snapshot, new_snapshot, changed_ranges)
    after
      File.rm_rf(root)
    end
  end

  defp build_snapshot(root, sources, plugins, config) do
    {paths, file_by_path} = write_sources(root, sources)
    project = Project.from_sources(paths, plugins: plugins)

    map_facts(project, file_by_path) ++ clone_facts(project, file_by_path, config)
  end

  defp write_sources(root, sources) do
    sources
    |> Enum.sort_by(&elem(&1, 0))
    |> Stream.with_index()
    |> Enum.reduce({[], %{}}, fn {{file, source}, index}, {paths, file_by_path} ->
      destination = Path.join([root, to_string(index), Path.basename(file)])
      File.mkdir_p!(Path.dirname(destination))
      File.write!(destination, source)
      {[destination | paths], Map.put(file_by_path, Path.expand(destination), file)}
    end)
    |> then(fn {paths, file_by_path} -> {Enum.reverse(paths), file_by_path} end)
  end

  defp map_facts(project, file_by_path) do
    accesses = MapContract.collect_key_accesses(project)
    dual_key_facts(accesses, file_by_path) ++ default_drift_facts(accesses, file_by_path)
  end

  defp dual_key_facts(accesses, file_by_path) do
    accesses
    |> Enum.filter(&complete_access?/1)
    |> Enum.group_by(fn access ->
      {access_module(access), access.logical_key, access_map_variable(access)}
    end)
    |> Enum.flat_map(fn {{module, key, variable}, grouped} ->
      representations = MapSet.new(grouped, & &1.representation)

      if MapSet.subset?(MapSet.new([:atom, :string]), representations) do
        [
          fact(
            :dual_key_contract,
            {module, key, variable},
            List.first(grouped).key_label,
            access_locations(grouped, file_by_path),
            length(grouped),
            :high
          )
        ]
      else
        []
      end
    end)
  end

  defp default_drift_facts(accesses, file_by_path) do
    accesses
    |> Enum.flat_map(&access_default/1)
    |> Enum.group_by(fn {access, _default} ->
      {access_module(access), access.logical_key, access_map_variable(access)}
    end)
    |> Enum.flat_map(fn {{module, key, variable}, grouped} ->
      defaults = grouped |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()

      if multiple?(defaults) do
        grouped_accesses = Enum.map(grouped, &elem(&1, 0))

        [
          fact(
            :default_drift,
            {module, key, variable, defaults},
            List.first(grouped_accesses).key_label,
            access_locations(grouped_accesses, file_by_path),
            length(grouped_accesses),
            :high
          )
        ]
      else
        []
      end
    end)
  end

  defp clone_facts(project, file_by_path, config) do
    project
    |> CloneAnalysis.analyze(config)
    |> Enum.filter(&(&1.type == :type_i and is_binary(&1.fingerprint)))
    |> Enum.flat_map(fn clone ->
      fragments = Enum.filter(clone.fragments, &(&1.whole_function == true))

      locations =
        fragments
        |> Enum.flat_map(&clone_location(&1, file_by_path))
        |> Enum.uniq()
        |> Enum.sort_by(&location_sort_key/1)

      if multiple?(fragments) do
        [fact(:exact_clone, clone.fingerprint, nil, locations, length(fragments), :medium)]
      else
        []
      end
    end)
  end

  defp fact(family, identity, key, locations, occurrences, confidence) do
    %{
      family: family,
      identity: identity,
      fingerprint: fingerprint({family, identity}),
      key: key && to_string(key),
      locations: Enum.uniq(locations) |> Enum.sort_by(&location_sort_key/1),
      occurrences: occurrences,
      confidence: confidence
    }
  end

  defp displaced(old_facts, new_facts, changed_ranges) do
    new_by_fingerprint = Map.new(new_facts, &{&1.fingerprint, &1})

    old_facts
    |> Enum.flat_map(fn old_fact ->
      case Map.get(new_by_fingerprint, old_fact.fingerprint) do
        nil -> []
        new_fact -> displaced_fact(old_fact, new_fact, changed_ranges)
      end
    end)
    |> Enum.sort_by(&{&1.family, &1.fingerprint})
  end

  defp displaced_fact(old_fact, new_fact, changed_ranges) do
    old_locations = changed_locations(old_fact.locations, changed_ranges, :old)
    new_locations = changed_locations(new_fact.locations, changed_ranges, :new)

    if old_locations != [] and new_locations != [] and
         MapSet.new(old_locations) != MapSet.new(new_locations) and
         new_fact.occurrences >= old_fact.occurrences do
      [
        DisplacedFact.new(
          family: old_fact.family,
          fingerprint: old_fact.fingerprint,
          key: old_fact.key,
          old_locations: old_locations,
          new_locations: new_locations,
          occurrences_before: old_fact.occurrences,
          occurrences_after: new_fact.occurrences,
          message: displacement_message(old_fact),
          suggestion: displacement_suggestion(old_fact),
          confidence: old_fact.confidence
        )
      ]
    else
      []
    end
  end

  defp displacement_message(%{family: :dual_key_contract, key: key}) do
    "atom/string representations for key #{inspect(key)} moved but the loose contract persists"
  end

  defp displacement_message(%{family: :default_drift, key: key}) do
    "conflicting defaults for key #{inspect(key)} moved but the default drift persists"
  end

  defp displacement_message(%{family: :exact_clone}) do
    "an exact clone fragment moved while the clone occurrence count stayed unchanged or increased"
  end

  defp displacement_suggestion(%{family: :dual_key_contract, key: key}) do
    "Normalize key #{inspect(key)} once at the boundary instead of moving dual-representation access into a helper"
  end

  defp displacement_suggestion(%{family: :default_drift, key: key}) do
    "Define the default for #{inspect(key)} once in the owning contract instead of relocating fallback reads"
  end

  defp displacement_suggestion(%{family: :exact_clone}) do
    "Consolidate the clone into one canonical implementation instead of relocating the duplicate"
  end

  defp changed_locations(locations, changed_ranges, side) do
    locations
    |> Enum.filter(fn location ->
      changed_ranges
      |> Map.get(location.file, [])
      |> Enum.map(&Range.normalize/1)
      |> Enum.any?(&line_in_range?(location.line, &1, side))
    end)
    |> Enum.sort_by(&location_sort_key/1)
  end

  defp line_in_range?(_line, %Range{old_count: 0}, :old), do: false

  defp line_in_range?(line, %Range{} = range, :old),
    do: line >= range.old_start and line < range.old_start + range.old_count

  defp line_in_range?(_line, %Range{new_count: 0}, :new), do: false

  defp line_in_range?(line, %Range{} = range, :new),
    do: line >= range.new_start and line < range.new_start + range.new_count

  defp complete_access?(access) do
    access.function && access.logical_key && access_map_variable(access) &&
      access.representation in [:atom, :string]
  end

  defp access_default(%{default_node: %{type: :literal, meta: %{value: value}}} = access)
       when not is_nil(access.function) and not is_nil(access.logical_key) do
    if access_map_variable(access), do: [{access, value}], else: []
  end

  defp access_default(_access), do: []

  defp access_module(%{function: {module, _function, _arity}}), do: module

  defp access_map_variable(%{node: %{children: [%{type: :var, meta: %{name: name}} | _]}}),
    do: name

  defp access_map_variable(_access), do: nil

  defp access_locations(accesses, file_by_path) do
    accesses
    |> Enum.flat_map(fn access ->
      normalized_location(access.node.source_span, access.function, file_by_path)
    end)
    |> Enum.uniq()
  end

  defp clone_location(fragment, file_by_path) do
    file = fragment.file && Map.get(file_by_path, Path.expand(fragment.file))

    if file && fragment.line do
      [
        %{
          file: file,
          line: fragment.line,
          function: clone_function(fragment)
        }
      ]
    else
      []
    end
  end

  defp normalized_location(%{file: path, start_line: line}, function, file_by_path) do
    case Map.get(file_by_path, Path.expand(path)) do
      nil -> []
      file -> [%{file: file, line: line, function: IRHelpers.func_id_to_string(function)}]
    end
  end

  defp normalized_location(_span, _function, _file_by_path), do: []

  defp clone_function(%{module: module, function: function, arity: arity})
       when not is_nil(function) and not is_nil(arity),
       do: IRHelpers.func_id_to_string({module, function, arity})

  defp clone_function(_fragment), do: nil

  defp location_sort_key(location),
    do: {location.file || "", location.line || 0, location.function || ""}

  defp multiple?([_first, _second | _rest]), do: true
  defp multiple?(_values), do: false

  defp fingerprint(term) do
    term
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&"sha256:#{&1}")
  end

  defp changed_source_files(changed_ranges) do
    changed_ranges
    |> Map.keys()
    |> Enum.filter(&(Path.extname(&1) in [".ex", ".exs"]))
    |> Enum.sort()
  end

  defp source_pairs(files, revision, opts) do
    Enum.reduce(files, {%{}, %{}}, fn file, {old_sources, new_sources} ->
      case {
        SourceSnapshot.source(:old, file, revision, opts),
        SourceSnapshot.source(:new, file, revision, opts)
      } do
        {{:ok, old_source}, {:ok, new_source}} ->
          {Map.put(old_sources, file, old_source), Map.put(new_sources, file, new_source)}

        _unavailable_pair ->
          {old_sources, new_sources}
      end
    end)
  end
end
