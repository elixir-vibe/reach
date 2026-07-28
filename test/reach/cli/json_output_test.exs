defmodule Reach.CLI.JSONOutputTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Reach.CLI.Commands.Check
  alias Reach.CLI.Commands.Inspect
  alias Reach.CLI.Commands.Map

  test "reach.map emits a consolidated json envelope" do
    project = fixture_project()
    output = capture_io(fn -> Map.run(format: "json", top: 2, project: project) end)

    assert String.starts_with?(output, "{")
    assert {:ok, data} = JSON.decode(output)
    assert data["command"] == "reach.map"
    assert is_map(data["summary"])
    assert is_map(data["sections"])
  end

  test "reach.map effect json includes provenance and unresolved call kinds" do
    project = fixture_project()

    output =
      capture_io(fn -> Map.run(format: "json", effects: true, top: 10, project: project) end)

    assert {:ok, %{"sections" => %{"effects" => effects}}} = JSON.decode(output)
    assert Enum.all?(effects["sources"], &:maps.is_key("confidence", &1))

    assert Enum.any?(effects["unknown_calls"], fn call ->
             call["module"] == "Graph" and call["function"] == "to_dot" and
               call["kind"] == "remote"
           end)
  end

  test "reach.inspect emits graph-backed candidates as json" do
    project = fixture_project()

    output =
      capture_io(fn ->
        Inspect.run([candidates: true, format: "json", project: project], ["candidate/2"])
      end)

    data = decode_json(output)
    assert data["target"] == "Demo.Main.candidate/2"
    assert is_list(data["candidates"])
  end

  test "reach.inspect emits consolidated context json" do
    project = fixture_project()

    output =
      capture_io(fn ->
        Inspect.run([context: true, format: "json", project: project], ["context/1"])
      end)

    data = decode_json(output)
    assert data["command"] == "reach.inspect"
    assert data["target"] == "Demo.Main.context/1"
    assert is_map(data["deps"])
    assert is_map(data["data"])
  end

  test "reach.inspect explains why one target reaches another" do
    project = fixture_project()

    output =
      capture_io(fn ->
        Inspect.run([why: "Graph.to_dot/1", format: "json", project: project], ["to_dot/1"])
      end)

    assert String.starts_with?(output, "{")
    assert {:ok, data} = JSON.decode(output)
    assert data["command"] == "reach.inspect"
    assert data["relation"] in ["call_path", "none"]
    assert is_list(data["paths"])
  end

  test "reach.check emits graph-backed candidates as pure json" do
    project = fixture_project()
    output = capture_io(fn -> Check.run(candidates: true, format: "json", project: project) end)

    assert {:ok, data} = JSON.decode(output)
    assert is_list(data["candidates"])
    assert Enum.all?(data["candidates"], &:maps.is_key("confidence", &1))
    assert Enum.all?(data["candidates"], &:maps.is_key("proof", &1))
  end

  defp fixture_project do
    path = fixture_file()
    Reach.Project.from_sources([path])
  end

  defp fixture_file do
    source = """
    defmodule Demo.Helper do
      def clean(value), do: String.trim(value)
    end

    defmodule Demo.Main do
      def to_dot(graph), do: Graph.to_dot(graph)
      def context(value), do: Demo.Helper.clean(value)

      def candidate(a, b) do
        x = a + 1
        y = b + 2
        z = x * y
        z + 3
      end
    end
    """

    dir = Path.join(System.tmp_dir!(), "reach-json-fixture-#{System.unique_integer()}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "sample.ex")
    File.write!(path, source)
    on_exit(fn -> File.rm_rf(dir) end)
    path
  end

  defp decode_json(output) do
    json =
      output
      |> String.split("\n")
      |> Enum.drop_while(&(not String.starts_with?(&1, "{")))
      |> Enum.join("\n")

    assert {:ok, data} = JSON.decode(json)
    data
  end
end
