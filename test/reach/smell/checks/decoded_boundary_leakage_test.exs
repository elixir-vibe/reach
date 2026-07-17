defmodule Reach.Smell.Checks.DecodedBoundaryLeakageTest do
  use ExUnit.Case, async: true

  alias Reach.Check.Smells
  alias Reach.Project

  test "promotes direct decoded boundary evidence into a high-confidence smell" do
    {project, path} =
      project("""
      defmodule StoredPayload do
        def cache(raw) do
          pricing = Jason.decode!(raw)
          :persistent_term.put(:payload, pricing)
        end

        def total(pricing), do: pricing["input"] + pricing["output"]
      end
      """)

    assert [finding] =
             project
             |> Smells.run([])
             |> Enum.filter(&(&1.kind == :decoded_boundary_leakage))

    assert finding.confidence == :high
    assert finding.location == "#{path}:4"
    assert finding.message =~ "Jason.decode!/1"
    assert finding.message =~ ":persistent_term.put/2"
    assert finding.evidence =~ "fix the boundary"
  end

  test "keeps intentionally dynamic decoded stores as evidence only" do
    {project, _path} =
      project("""
      defmodule DynamicPayloadStore do
        use GenServer

        def init(raw), do: {:ok, Jason.decode!(raw)}

        def handle_call({:fetch, key}, _from, data) do
          {:reply, Map.get(data, key), data}
        end
      end
      """)

    assert Reach.Evidence.external_data_boundaries(project) != []
    refute Enum.any?(Smells.run(project, []), &(&1.kind == :decoded_boundary_leakage))
  end

  test "does not borrow fixed-key evidence from unrelated variables" do
    {project, _path} =
      project("""
      defmodule UnrelatedKeys do
        def cache(raw) do
          decoded = Jason.decode!(raw)
          :persistent_term.put(:payload, decoded)
        end

        def configure(config), do: Map.get(config, :timeout) + Map.get(config, :retries)
      end
      """)

    refute Enum.any?(Smells.run(project, []), &(&1.kind == :decoded_boundary_leakage))
  end

  test "does not borrow fixed-key evidence from another module in the file" do
    {project, _path} =
      project("""
      defmodule DynamicStore do
        use GenServer
        def init(raw), do: {:ok, Jason.decode!(raw)}
      end

      defmodule UnrelatedConsumer do
        def total(payload), do: payload["input"] + payload["output"]
      end
      """)

    refute Enum.any?(Smells.run(project, []), &(&1.kind == :decoded_boundary_leakage))
  end

  test "a source suppression can justify an intentional raw boundary" do
    {project, _path} =
      project("""
      defmodule SuppressedPayload do
        def cache(raw) do
          pricing = Jason.decode!(raw)
          # reach:disable-next-line decoded_boundary_leakage -- shared cache intentionally preserves upstream JSON shape
          :persistent_term.put(:payload, pricing)
        end

        def total(pricing), do: pricing["input"] + pricing["output"]
      end
      """)

    refute Enum.any?(Smells.run(project, []), &(&1.kind == :decoded_boundary_leakage))
  end

  defp project(source) do
    path =
      Path.join(
        System.tmp_dir!(),
        "reach-decoded-boundary-#{System.unique_integer([:positive])}.ex"
      )

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)
    {Project.from_sources([path], plugins: [Reach.Plugins.Jason]), path}
  end
end
