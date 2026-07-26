defmodule Reach.Check.Baseline do
  @moduledoc false

  alias Reach.Check.{AnalysisScope, Finding}

  @derive JSON.Encoder
  defstruct version: 2, tool: "reach", findings: [], scopes: %{}

  def path(opts, config) do
    opts[:baseline] || config.checks.baseline
  end

  def write_path(opts), do: opts[:write_baseline]

  def filter(findings, nil), do: {findings, []}

  def filter(findings, path) do
    baseline = read(path)
    known = MapSet.new(Enum.map(baseline.findings, & &1.fingerprint))
    Enum.split_with(findings, &(!MapSet.member?(known, &1.fingerprint)))
  end

  def write(path, source, findings, scope \\ nil) do
    existing = read(path)
    source = to_string(source)

    retained =
      Enum.reject(existing.findings, fn finding ->
        to_string(finding.source) == source
      end)

    scopes =
      if scope,
        do: Map.put(existing.scopes, source, scope),
        else: Map.delete(existing.scopes, source)

    baseline = %__MODULE__{
      existing
      | version: 2,
        findings: Enum.sort_by(retained ++ findings, &sort_key/1),
        scopes: scopes
    }

    File.write!(path, JSON.encode!(baseline) <> "\n")
  end

  def validate_scope(nil, _source, _scope), do: :ok
  def validate_scope(_path, _source, nil), do: :ok

  def validate_scope(path, source, %AnalysisScope{} = current_scope) do
    if File.exists?(path) do
      validate_existing_scope(path, source, current_scope)
    else
      :ok
    end
  end

  defp validate_existing_scope(path, source, current_scope) do
    baseline = read(path)

    case Map.get(baseline.scopes, to_string(source)) do
      nil ->
        :legacy

      baseline_scope ->
        baseline_scope = AnalysisScope.from_map(baseline_scope)

        if AnalysisScope.compatible?(baseline_scope, current_scope) do
          :ok
        else
          {:error,
           "Baseline #{path} was created for a different analysis scope. " <>
             "Expected #{AnalysisScope.describe(baseline_scope)}; " <>
             "current scope is #{AnalysisScope.describe(current_scope)}. " <>
             "Use the same MIX_ENV/source paths or regenerate the baseline."}
        end
    end
  end

  def read(nil), do: %__MODULE__{}

  def read(path) do
    if File.exists?(path) do
      path
      |> File.read!()
      |> JSON.decode!()
      |> from_map()
    else
      %__MODULE__{}
    end
  end

  defp from_map(data) do
    findings = field(data, :findings, [])

    scopes =
      data
      |> field(:scopes, %{})
      |> Map.new(fn {source, scope} -> {to_string(source), AnalysisScope.from_map(scope)} end)

    %__MODULE__{
      version: field(data, :version, 1),
      tool: field(data, :tool, "reach"),
      findings: Enum.map(findings, &finding_from_map/1),
      scopes: scopes
    }
  end

  defp finding_from_map(data) do
    %Finding{
      source: field(data, :source),
      kind: field(data, :kind),
      fingerprint: field!(data, :fingerprint),
      message: field(data, :message),
      file: field(data, :file),
      line: field(data, :line)
    }
  end

  defp field(map, key, default \\ nil),
    do: Map.get(map, key) || Map.get(map, to_string(key), default)

  defp field!(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.fetch!(map, to_string(key))
    end
  end

  defp sort_key(finding) do
    {to_string(finding.source), to_string(finding.file), finding.line || 0,
     to_string(finding.kind)}
  end
end
