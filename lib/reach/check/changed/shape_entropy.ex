defmodule Reach.Check.Changed.ShapeEntropy do
  @moduledoc "Detects parameter map-shape entropy increases across source revisions."

  alias Reach.Check.Changed.EntropyRegression
  alias Reach.Check.Changed.Range
  alias Reach.Check.Changed.SourceSnapshot
  alias Reach.Config
  alias Reach.Evidence.ParameterShape
  alias Reach.Project
  alias Reach.Smell.ParameterShapePolicy
  alias Reach.Source

  @spec analyze(Project.t(), String.t(), map(), Config.t() | keyword(), keyword()) :: [
          EntropyRegression.t()
        ]
  def analyze(project, base, changed_ranges, config, opts \\ []) do
    current_facts = ParameterShape.collect_project(project)

    if changed_shape_call?(current_facts, changed_ranges) do
      compare_revision(project, current_facts, base, changed_ranges, config, opts)
    else
      []
    end
  end

  defp compare_revision(project, current_facts, base, changed_ranges, config, opts) do
    config = Config.normalize(config)
    revision = SourceSnapshot.revision(base, opts)

    case old_project(project, revision, changed_ranges, opts) do
      {:ok, old_project, root} ->
        try do
          compare(
            ParameterShape.collect_project(old_project),
            current_facts,
            changed_ranges,
            config.smells.parameter_shape_entropy
          )
        after
          File.rm_rf(root)
        end

      _unavailable ->
        []
    end
  end

  defp changed_shape_call?(facts, changed_ranges) do
    Enum.any?(facts, fn fact ->
      Enum.any?(fact.occurrences, &changed_line?(changed_ranges, &1.file, &1.line))
    end)
  end

  defp old_project(project, revision, changed_ranges, opts) do
    root =
      Path.join(
        System.tmp_dir!(),
        "reach-shape-entropy-#{System.unique_integer([:positive, :monotonic])}"
      )

    files = Source.project_files(project)

    paths =
      files
      |> Enum.with_index()
      |> Enum.flat_map(fn {file, index} ->
        source = old_source(file, revision, changed_ranges, opts)
        write_source(root, file, index, source)
      end)

    if paths == [] do
      File.rm_rf(root)
      {:error, :missing_old_sources}
    else
      old_project = Project.from_sources(paths, plugins: Map.get(project, :plugins, []))
      {:ok, old_project, root}
    end
  end

  defp old_source(file, revision, changed_ranges, opts) do
    if Map.has_key?(changed_ranges, file) do
      SourceSnapshot.source(:old, file, revision, opts)
    else
      File.read(file)
    end
  end

  defp write_source(_root, _file, _index, {:error, _reason}), do: []

  defp write_source(root, file, index, {:ok, source}) do
    destination = Path.join([root, to_string(index), Path.basename(file)])
    File.mkdir_p!(Path.dirname(destination))
    File.write!(destination, source)
    [destination]
  end

  defp compare(old_facts, new_facts, changed_ranges, config) do
    old_by_parameter = Map.new(old_facts, &{{&1.target, &1.parameter_index}, &1})

    new_facts
    |> Enum.filter(
      &(ParameterShapePolicy.eligible?(&1, config) and changed_fact?(&1, changed_ranges))
    )
    |> Enum.flat_map(fn fact ->
      old = Map.get(old_by_parameter, {fact.target, fact.parameter_index})
      regression(fact, old, config)
    end)
    |> Enum.sort_by(&{&1.file || "", &1.line || 0, &1.target, &1.parameter_index})
  end

  defp regression(new, old, config) do
    old_entropy = if old, do: old.entropy, else: 0.0
    delta = new.entropy - old_entropy

    if delta >= config.min_entropy_delta do
      [
        %EntropyRegression{
          target: format_target(new.target),
          parameter: to_string(new.parameter),
          parameter_index: new.parameter_index,
          file: new.file,
          line: new.line,
          old_entropy: old_entropy,
          new_entropy: new.entropy,
          delta: delta,
          old_variants: if(old, do: old.variants, else: []),
          new_variants: new.variants,
          changed_locations: changed_locations(new)
        }
      ]
    else
      []
    end
  end

  defp changed_fact?(fact, changed_ranges) do
    changed_line?(changed_ranges, fact.file, fact.line) or
      Enum.any?(fact.occurrences, &changed_line?(changed_ranges, &1.file, &1.line))
  end

  defp changed_locations(fact) do
    fact.occurrences
    |> Enum.map(&"#{&1.file}:#{&1.line}")
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp changed_line?(_ranges, nil, _line), do: false
  defp changed_line?(_ranges, _file, nil), do: false

  defp changed_line?(ranges, file, line) do
    ranges
    |> Map.get(file, [])
    |> Enum.any?(&(Range.normalize(&1) |> Range.contains_line?(:new, line)))
  end

  defp format_target({module, function, arity}), do: "#{inspect(module)}.#{function}/#{arity}"
end
