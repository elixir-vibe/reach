defmodule ReachCalibration.Sources.ExographTest do
  use ExUnit.Case, async: true

  alias ReachCalibration.Selection
  alias ReachCalibration.Sources.Exograph, as: ExographClient

  test "selects package versions through the versioned query API" do
    parent = self()

    request = fn url, body ->
      send(parent, {:request, url, body})
      {:ok, %{"results" => [%{"package_name" => "demo", "version" => "1.0.0"}]}}
    end

    assert {:ok,
            %Selection{
              versions: [%{"package_name" => "demo"}],
              strategy: :all,
              pool_size: 1
            }} =
             ExographClient.package_versions(
               base_url: "http://exograph.test/",
               limit: 3,
               request: request
             )

    assert_receive {:request, "http://exograph.test/api/query", body}
    assert body["query"]["version"] == 1
    assert body["query"]["source"] == "package_version"
    assert body["query"]["limit"] == 3
  end

  test "uses indexed fragment candidates when all requested kinds have prefilters" do
    parent = self()

    request = fn url, body ->
      send(parent, {:request, url, body})

      {:ok,
       %{
         "results" => [
           %{
             "package" => "demo",
             "package_version" => "1.0.0",
             "file" => "lib/demo/b.ex"
           },
           %{
             "package" => "demo",
             "package_version" => "1.0.0",
             "file" => "lib/demo/a.ex"
           }
         ]
       }}
    end

    assert {:ok,
            %Selection{
              versions: [
                %{
                  "package_name" => "demo",
                  "version" => "1.0.0",
                  "candidate_paths" => ["lib/demo/a.ex", "lib/demo/b.ex"],
                  "candidate_patterns" => ["Map.get(_, _)"]
                }
              ],
              strategy: :stratified,
              pool_size: 1,
              patterns: ["Map.get(_, _)"]
            }} =
             ExographClient.package_versions(
               base_url: "http://exograph.test",
               limit: 5,
               kinds: MapSet.new([:dual_key_fallback]),
               request: request
             )

    assert_receive {:request, "http://exograph.test/api/query", body}
    assert body["query"]["source"] == "fragment"

    assert [%{"op" => "contains", "value" => "Map.get(_, _)"}] =
             body["query"]["predicates"]
  end

  test "follows candidate cursors before deduplicating package versions" do
    request = fn _url, body ->
      case body["cursor"] do
        nil ->
          {:ok,
           %{
             "results" => [%{"package" => "alpha", "package_version" => "1.0.0"}],
             "next_cursor" => "next"
           }}

        "next" ->
          {:ok,
           %{
             "results" => [%{"package" => "beta", "package_version" => "2.0.0"}],
             "next_cursor" => nil
           }}
      end
    end

    assert {:ok, %Selection{versions: versions, pool_size: 2}} =
             ExographClient.package_versions(
               base_url: "http://exograph.test",
               limit: 2,
               candidate_limit: 10,
               kinds: MapSet.new([:dual_key_fallback]),
               request: request
             )

    assert versions |> Enum.map(& &1["package_name"]) |> MapSet.new() ==
             MapSet.new(["alpha", "beta"])
  end

  test "retries rate-limited HTTP requests using the server delay" do
    parent = self()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    http = fn _url, _body ->
      Agent.get_and_update(attempts, fn
        0 ->
          response =
            {:ok,
             %{
               status: 429,
               body: %{"error" => %{"details" => %{"retry_after_ms" => 5}}}
             }}

          {response, 1}

        count ->
          {{:ok, %{status: 200, body: %{"ok" => true}}}, count + 1}
      end)
    end

    sleep = fn delay -> send(parent, {:slept, delay}) end

    assert {:ok, %{"ok" => true}} =
             ExographClient.request("http://exograph.test", %{}, http: http, sleep: sleep)

    assert_receive {:slept, 30}
    assert Agent.get(attempts, & &1) == 2
  end

  test "hydrates only indexed candidate paths by default" do
    parent = self()

    request = fn url, body ->
      send(parent, {:request, url, body})
      {:ok, %{"fingerprint" => "snapshot"}}
    end

    version = %{
      "ecosystem" => "hex",
      "package_name" => "demo",
      "version" => "1.0.0",
      "candidate_paths" => ["lib/demo/a.ex", "lib/demo/b.ex"]
    }

    assert {:ok, %{"fingerprint" => "snapshot"}} =
             ExographClient.hydrate(version,
               base_url: "http://exograph.test",
               request: request
             )

    assert_receive {:request, "http://exograph.test/api/hydrate", body}
    assert body["paths"] == ["lib/demo/a.ex", "lib/demo/b.ex"]
  end

  test "hydrates the selected package version" do
    parent = self()

    request = fn url, body ->
      send(parent, {:request, url, body})
      {:ok, %{"fingerprint" => "snapshot"}}
    end

    version = %{
      "ecosystem" => "hex",
      "package_name" => "demo",
      "version" => "1.0.0",
      "candidate_paths" => ["lib/candidate.ex"]
    }

    assert {:ok, %{"fingerprint" => "snapshot"}} =
             ExographClient.hydrate(version,
               base_url: "http://exograph.test",
               paths: ["lib/**", "config/**"],
               request: request
             )

    assert_receive {:request, "http://exograph.test/api/hydrate", body}
    assert body["packageName"] == "demo"
    assert body["paths"] == ["lib/**", "config/**"]
  end
end
