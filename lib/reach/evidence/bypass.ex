defmodule Reach.Evidence.Bypass do
  @moduledoc "Normalizes evidence that code reimplements an available capability."

  alias Reach.Evidence.Fact

  @category :capability_bypass

  @type origin :: :stdlib_pattern | :plugin_pattern | :dependency_clone

  @required_options [:provider, :capability, :origin]

  @doc "Builds a normalized capability-bypass fact."
  @spec fact(keyword()) :: Fact.t()
  def fact(attrs) do
    {bypass, fact_attrs} = Keyword.split(attrs, @required_options)

    data =
      fact_attrs
      |> Keyword.get(:data)
      |> then(&Map.new(&1 || %{}))
      |> Map.merge(bypass_metadata(bypass))

    fact_attrs
    |> Keyword.put(:data, data)
    |> then(&struct!(Fact, &1))
  end

  @doc "Adds normalized capability-bypass metadata to an existing fact."
  @spec annotate(Fact.t(), keyword()) :: Fact.t()
  def annotate(%Fact{} = fact, attrs) do
    %{fact | data: Map.merge(Map.new(fact.data || %{}), bypass_metadata(attrs))}
  end

  @doc "Converts cross-dependency clone families into project-located bypass facts."
  @spec from_dependency_clones([Reach.Evidence.CloneAnalysis.Clone.t()]) :: [Fact.t()]
  def from_dependency_clones(clones) do
    Enum.flat_map(clones, &dependency_clone_facts/1)
  end

  @doc "Returns whether an evidence fact represents an available-capability bypass."
  @spec fact?(term()) :: boolean()
  def fact?(%Fact{data: %{category: @category}}), do: true
  def fact?(_fact), do: false

  defp bypass_metadata(attrs) do
    @required_options
    |> Map.new(&{&1, Keyword.fetch!(attrs, &1)})
    |> Map.put(:category, @category)
  end

  defp dependency_clone_facts(clone) do
    project_fragments =
      clone.fragments
      |> Enum.filter(&(&1.origin == :project))
      |> Enum.sort_by(&fragment_sort_key/1)

    clone.fragments
    |> Enum.filter(&(&1.origin == :dependency))
    |> Enum.group_by(& &1.dependency)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {dependency, dependency_fragments} ->
      dependency_fragments = Enum.sort_by(dependency_fragments, &fragment_sort_key/1)

      Enum.map(project_fragments, fn project_fragment ->
        dependency_clone_fact(clone, project_fragment, dependency, dependency_fragments)
      end)
    end)
  end

  defp dependency_clone_fact(clone, project_fragment, dependency, dependency_fragments) do
    replacement = dependency_fragments |> hd() |> fragment_location()

    fact(
      family: :dependency_bypass,
      kind: :structural_reimplementation,
      message:
        "project code structurally duplicates source in dependency #{inspect(dependency)}; reuse the dependency implementation or document why this copy must diverge",
      replacement: replacement,
      meta: [file: project_fragment.file, line: project_fragment.line],
      confidence: clone_confidence(clone),
      source: :clone_analysis,
      data: %{
        clone: clone,
        project_fragment: project_fragment,
        dependency_fragments: dependency_fragments
      },
      provider: dependency,
      capability: :structural_reimplementation,
      origin: :dependency_clone
    )
  end

  defp clone_confidence(%{similarity: 1.0}), do: :high
  defp clone_confidence(_clone), do: :medium

  defp fragment_location(fragment), do: "#{fragment.file}:#{fragment.line}"
  defp fragment_sort_key(fragment), do: {fragment.file || "", fragment.line || 0}
end
