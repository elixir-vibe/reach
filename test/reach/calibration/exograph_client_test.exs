defmodule Reach.Calibration.ExographClientTest do
  use ExUnit.Case, async: true

  alias Reach.Calibration.ExographClient

  test "selects package versions through the versioned query API" do
    parent = self()

    request = fn url, body ->
      send(parent, {:request, url, body})
      {:ok, %{"results" => [%{"package_name" => "demo", "version" => "1.0.0"}]}}
    end

    assert {:ok, [%{"package_name" => "demo"}]} =
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
            [
              %{
                "package_name" => "demo",
                "version" => "1.0.0",
                "candidate_paths" => ["lib/demo/a.ex", "lib/demo/b.ex"]
              }
            ]} =
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

    assert {:ok, versions} =
             ExographClient.package_versions(
               base_url: "http://exograph.test",
               limit: 2,
               candidate_limit: 10,
               kinds: MapSet.new([:dual_key_fallback]),
               request: request
             )

    assert Enum.map(versions, & &1["package_name"]) == ["alpha", "beta"]
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
