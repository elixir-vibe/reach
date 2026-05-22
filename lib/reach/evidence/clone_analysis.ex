defmodule Reach.Evidence.CloneAnalysis do
  @moduledoc "Process-dictionary-cached clone detection dispatcher."

  alias Reach.Config
  alias Reach.Evidence.CloneAnalysis.ExDNA

  @cache_key {__MODULE__, :clones}

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

  defp do_analyze(project, %{provider: :ex_dna} = config), do: ExDNA.analyze(project, config)
  defp do_analyze(_project, _config), do: []

  defp project_fingerprint(project) do
    project.nodes
    |> Map.keys()
    |> :erlang.phash2()
  end
end
