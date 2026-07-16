defmodule ReachCalibration.Analyzer do
  @moduledoc "Runs Reach smell analysis against an explicitly hydrated source snapshot."

  alias Reach.Check.Smells

  @spec analyze(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def analyze(snapshot, opts \\ []) when is_map(snapshot) do
    root =
      Path.join(
        System.tmp_dir!(),
        "reach-exograph-#{System.unique_integer([:positive, :monotonic])}"
      )

    try do
      with {:ok, paths} <- write_files(root, snapshot["files"] || []),
           {:ok, findings} <- analyze_paths(paths, root, opts) do
        {:ok, package_result(snapshot, findings)}
      end
    after
      File.rm_rf(root)
    end
  end

  defp write_files(root, files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, paths} ->
      path = file["path"]

      if safe_path?(path) and is_binary(file["source"]) do
        destination = Path.join(root, path)
        File.mkdir_p!(Path.dirname(destination))
        File.write!(destination, file["source"])
        {:cont, {:ok, [destination | paths]}}
      else
        {:halt, {:error, {:invalid_snapshot_path, path}}}
      end
    end)
    |> case do
      {:ok, paths} -> {:ok, Enum.reverse(paths)}
      {:error, _reason} = error -> error
    end
  end

  defp safe_path?(path) when is_binary(path) do
    Path.type(path) == :relative and ".." not in Path.split(path)
  end

  defp safe_path?(_path), do: false

  defp analyze_paths(paths, root, opts) do
    plugins = Keyword.get_lazy(opts, :plugins, &Reach.Plugin.detect/0)
    kinds = Keyword.get(opts, :kinds)

    project = Reach.Project.from_sources(paths, plugins: plugins)

    findings =
      project
      |> Smells.run()
      |> filter_kinds(kinds)
      |> Enum.map(&finding(&1, root))

    {:ok, findings}
  catch
    kind, reason -> {:error, Exception.format(kind, reason, __STACKTRACE__)}
  end

  defp filter_kinds(findings, nil), do: findings
  defp filter_kinds(findings, kinds), do: Enum.filter(findings, &MapSet.member?(kinds, &1.kind))

  defp finding(finding, root) do
    %{
      "kind" => to_string(finding.kind),
      "location" => relative_location(finding.location, root),
      "message" => finding.message,
      "confidence" => json_value(finding.confidence),
      "evidence" => finding.evidence |> json_value() |> relative_paths(root)
    }
  end

  defp relative_location(location, root) do
    String.replace_prefix(location, root <> "/", "")
  end

  defp relative_paths(value, root) when is_binary(value),
    do: String.replace_prefix(value, root <> "/", "")

  defp relative_paths(values, root) when is_list(values),
    do: Enum.map(values, &relative_paths(&1, root))

  defp relative_paths(value, root) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, relative_paths(item, root)} end)

  defp relative_paths(value, _root), do: value

  defp package_result(snapshot, findings) do
    version = snapshot["package_version"] || %{}

    %{
      "ecosystem" => version["ecosystem"],
      "package" => version["package_name"],
      "version" => version["version"],
      "snapshot_fingerprint" => snapshot["fingerprint"],
      "files" => length(snapshot["files"] || []),
      "findings" => findings
    }
  end

  defp json_value(nil), do: nil
  defp json_value(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp json_value(value) when is_atom(value), do: Atom.to_string(value)

  defp json_value(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&json_value/1)

  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)
  defp json_value(%_{} = value), do: value |> Map.from_struct() |> json_value()

  defp json_value(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), json_value(item)} end)
  end

  defp json_value(value), do: inspect(value)
end
