defmodule Reach.Calibration.ExographClient do
  @moduledoc "HTTP consumer for Exograph's versioned query and hydration API."

  @behaviour Reach.Calibration.Source

  @type request_fun :: (String.t(), map() -> {:ok, map()} | {:error, term()})
  @type package_version :: %{String.t() => term()}

  alias Reach.Calibration.Candidates

  @candidate_multiplier 20

  @spec package_versions(keyword()) :: {:ok, [map()]} | {:error, term()}
  def package_versions(opts) do
    if Keyword.get(opts, :limit, 25) > 0 do
      case Candidates.patterns(Keyword.get(opts, :kinds)) do
        :all -> all_package_versions(opts)
        patterns -> candidate_package_versions(patterns, opts)
      end
    else
      {:error, :invalid_package_limit}
    end
  end

  defp all_package_versions(opts) do
    query = %{
      "version" => 1,
      "source" => "package_version",
      "binding" => "v",
      "predicates" => [],
      "joins" => [],
      "limit" => Keyword.get(opts, :limit, 25)
    }

    with {:ok, response} <- post(opts, "/api/query", %{"query" => query}),
         results when is_list(results) <- response["results"] do
      {:ok, results}
    else
      nil -> {:error, :missing_query_results}
      {:error, _reason} = error -> error
    end
  end

  defp candidate_package_versions(patterns, opts) do
    limit = Keyword.get(opts, :limit, 25)

    candidate_limit =
      Keyword.get(opts, :candidate_limit, max(limit * @candidate_multiplier, limit))

    patterns
    |> Enum.reduce_while({:ok, []}, fn pattern, {:ok, versions} ->
      case candidate_versions(pattern, candidate_limit, opts) do
        {:ok, candidates} -> {:cont, {:ok, [candidates | versions]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, version_groups} ->
        versions =
          version_groups
          |> Enum.reverse()
          |> List.flatten()
          |> merge_candidate_versions()
          |> Enum.take(limit)

        {:ok, versions}

      {:error, _reason} = error ->
        error
    end
  end

  defp candidate_versions(pattern, limit, opts) do
    fetch_candidate_pages(pattern, min(limit, 200), limit, nil, [], 0, opts)
  end

  defp fetch_candidate_pages(pattern, page_size, limit, cursor, versions, seen, opts) do
    query = %{
      "version" => 1,
      "source" => "fragment",
      "binding" => "f",
      "predicates" => [%{"op" => "contains", "binding" => "f", "value" => pattern}],
      "joins" => [],
      "limit" => min(page_size, limit - seen)
    }

    body = %{"query" => query, "cursor" => cursor}

    with {:ok, response} <- post(opts, "/api/query", body),
         results when is_list(results) <- response["results"] do
      candidates = results |> Enum.map(&candidate_version/1) |> Enum.reject(&is_nil/1)
      seen = seen + length(results)
      versions = candidates ++ versions
      next_cursor = response["next_cursor"]

      if is_binary(next_cursor) and results != [] and seen < limit do
        fetch_candidate_pages(pattern, page_size, limit, next_cursor, versions, seen, opts)
      else
        {:ok, Enum.reverse(versions)}
      end
    else
      nil -> {:error, :missing_query_results}
      {:error, _reason} = error -> error
    end
  end

  defp candidate_version(%{"package" => package, "package_version" => version} = result)
       when is_binary(package) and is_binary(version) do
    candidate = %{"ecosystem" => "hex", "package_name" => package, "version" => version}

    case result["file"] do
      path when is_binary(path) -> Map.put(candidate, "candidate_paths", [path])
      _other -> candidate
    end
  end

  defp candidate_version(_result), do: nil

  defp merge_candidate_versions(versions) do
    {identities, versions_by_identity} =
      Enum.reduce(versions, {[], %{}}, fn version, {identities, versions_by_identity} ->
        identity = version_identity(version)

        case Map.fetch(versions_by_identity, identity) do
          {:ok, existing} ->
            merged = merge_candidate_paths(existing, version)
            {identities, Map.put(versions_by_identity, identity, merged)}

          :error ->
            {[identity | identities], Map.put(versions_by_identity, identity, version)}
        end
      end)

    identities
    |> Enum.reverse()
    |> Enum.map(&Map.fetch!(versions_by_identity, &1))
  end

  defp merge_candidate_paths(left, right) do
    paths =
      (Map.get(left, "candidate_paths", []) ++ Map.get(right, "candidate_paths", []))
      |> Enum.uniq()
      |> Enum.sort()

    if paths == [], do: left, else: Map.put(left, "candidate_paths", paths)
  end

  defp version_identity(version) do
    {version["ecosystem"], version["package_name"], version["version"]}
  end

  @spec hydrate(package_version(), keyword()) :: {:ok, map()} | {:error, term()}
  def hydrate(version, opts) when is_map(version) do
    body = %{
      "ecosystem" => version["ecosystem"] || "hex",
      "packageName" => version["package_name"],
      "version" => version["version"],
      "paths" => hydration_paths(version, opts)
    }

    post(opts, "/api/hydrate", body)
  end

  defp hydration_paths(version, opts) do
    paths = Keyword.get(opts, :paths) || Map.get(version, "candidate_paths", [])
    default_paths(paths)
  end

  defp default_paths([]), do: ["lib/**"]
  defp default_paths(paths), do: paths

  defp post(opts, path, body) do
    base_url = Keyword.fetch!(opts, :base_url)
    request = Keyword.get(opts, :request, &request/2)
    request.(String.trim_trailing(base_url, "/") <> path, body)
  end

  defp request(url, body) do
    :inets.start()
    :ssl.start()

    request = {
      String.to_charlist(url),
      [{~c"content-type", ~c"application/json"}],
      ~c"application/json",
      JSON.encode!(body)
    }

    case :httpc.request(:post, request, [timeout: 30_000], body_format: :binary) do
      {:ok, {{_http_version, status, _reason}, _headers, response_body}}
      when status in 200..299 ->
        JSON.decode(response_body)

      {:ok, {{_http_version, status, _reason}, _headers, response_body}} ->
        {:error, {:http_error, status, decode_error(response_body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_error(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end
end
