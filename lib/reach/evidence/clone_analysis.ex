defmodule Reach.Evidence.CloneAnalysis do
  @moduledoc "Process-dictionary-cached clone detection dispatcher."

  alias Reach.Config
  alias Reach.Evidence.Bypass
  alias Reach.Evidence.CloneAnalysis.ExDNA

  @cache_key {__MODULE__, :clones}
  @dependency_cache_key {__MODULE__, :dependency_bypass}

  def analyze(project, config \\ []) do
    config = Config.normalize(config).clone_analysis
    key = {project_fingerprint(project), config}

    case Process.get({@cache_key, key}) do
      nil ->
        clones = do_analyze(project, config)
        Process.put({@cache_key, key}, clones)
        clones

      clones ->
        clones
    end
  end

  @doc "Returns capability-bypass facts backed by project-to-dependency clones."
  def dependency_bypass(project, config \\ []) do
    config = Config.normalize(config).clone_analysis
    key = {project_fingerprint(project), config}

    case Process.get({@dependency_cache_key, key}) do
      nil ->
        facts = do_dependency_bypass(project, config)
        Process.put({@dependency_cache_key, key}, facts)
        facts

      facts ->
        facts
    end
  end

  defp do_analyze(project, %{provider: :ex_dna} = config), do: ExDNA.analyze(project, config)
  defp do_analyze(_project, _config), do: []

  defp do_dependency_bypass(project, %{provider: :ex_dna, include_deps: true} = config) do
    project
    |> ExDNA.dependency_clones(config)
    |> Bypass.from_dependency_clones()
  end

  defp do_dependency_bypass(_project, _config), do: []

  defp project_fingerprint(project) do
    project.nodes
    |> Map.keys()
    |> :erlang.phash2()
  end
end
