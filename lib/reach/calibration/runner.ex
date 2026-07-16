defmodule Reach.Calibration.Runner do
  @moduledoc "Coordinates Exograph selection and hydration with local Reach analysis."

  alias Reach.Calibration.{Analyzer, ExographClient}

  @verdicts ["true_positive", "false_positive", "unreviewed"]

  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts) do
    client = Keyword.get(opts, :client, ExographClient)
    labels = load_labels(Keyword.get(opts, :labels))

    with {:ok, versions} <- client.package_versions(opts) do
      packages = Enum.map(versions, &analyze_version(client, &1, labels, opts))

      {:ok,
       %{
         "version" => 1,
         "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
         "selection" => selection(opts),
         "packages" => packages,
         "summary" => summarize(packages)
       }}
    end
  end

  defp selection(opts) do
    kinds =
      case Keyword.get(opts, :kinds) do
        nil -> nil
        kinds -> kinds |> Enum.map(&to_string/1) |> Enum.sort()
      end

    paths = Keyword.get(opts, :paths)

    %{
      "limit" => Keyword.get(opts, :limit, 25),
      "kinds" => kinds,
      "paths" => paths,
      "hydration_scope" => if(paths, do: "explicit_paths", else: "candidate_paths_or_lib")
    }
  end

  defp analyze_version(client, version, labels, opts) do
    with {:ok, snapshot} <- client.hydrate(version, opts),
         {:ok, result} <- Analyzer.analyze(snapshot, opts) do
      findings = Enum.map(result["findings"], &label_finding(&1, result, labels))
      Map.put(result, "findings", findings)
    else
      {:error, reason} ->
        %{
          "ecosystem" => version["ecosystem"],
          "package" => version["package_name"],
          "version" => version["version"],
          "error" => inspect(reason),
          "findings" => []
        }
    end
  end

  defp label_finding(finding, package, labels) do
    id = finding_id(finding, package)
    verdict = Map.get(labels, id, "unreviewed")
    finding |> Map.put("id", id) |> Map.put("verdict", verdict)
  end

  defp finding_id(finding, package) do
    payload =
      [
        package["ecosystem"],
        package["package"],
        package["version"],
        package["snapshot_fingerprint"],
        finding["kind"],
        finding["location"],
        finding["message"]
      ]
      |> Enum.join("\0")

    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end

  defp load_labels(nil), do: %{}

  defp load_labels(path) do
    path
    |> File.read!()
    |> JSON.decode!()
    |> Map.new(fn {id, verdict} ->
      if verdict in @verdicts do
        {id, verdict}
      else
        raise ArgumentError, "unsupported calibration verdict #{inspect(verdict)} for #{id}"
      end
    end)
  end

  defp summarize(packages) do
    findings = Enum.flat_map(packages, & &1["findings"])

    %{
      "packages" => length(packages),
      "errors" => Enum.count(packages, &Map.has_key?(&1, "error")),
      "findings" => length(findings),
      "by_kind" =>
        findings
        |> Enum.group_by(& &1["kind"])
        |> Map.new(fn {kind, kind_findings} -> {kind, metrics(kind_findings)} end)
    }
  end

  defp metrics(findings) do
    true_positives = Enum.count(findings, &(&1["verdict"] == "true_positive"))
    false_positives = Enum.count(findings, &(&1["verdict"] == "false_positive"))
    reviewed = true_positives + false_positives
    total = length(findings)

    %{
      "total" => total,
      "reviewed" => reviewed,
      "true_positives" => true_positives,
      "false_positives" => false_positives,
      "unreviewed" => total - reviewed,
      "precision" => if(reviewed == 0, do: nil, else: true_positives / reviewed)
    }
  end
end
