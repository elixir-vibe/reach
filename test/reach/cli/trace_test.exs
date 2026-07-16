defmodule Reach.CLI.TraceTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Reach.CLI.Commands.Trace

  test "reach.trace runs variable tracing directly" do
    project = fixture_project()

    output =
      capture_io(fn ->
        Trace.run(variable: "graph", in: "run/1", format: "oneline", project: project)
      end)

    assert output =~ "graph"
  end

  test "reach.trace runs named trace presets" do
    project =
      project_from_source("""
      defmodule StructuredTraceFixture do
        def run do
          xml = File.read!("priv/items.xml")
          Regex.scan(~r/<item>/, xml)
        end
      end
      """)

    output =
      capture_io(fn ->
        Trace.run(pattern: "regex-on-structured", format: "text", project: project)
      end)

    assert output =~ "structured file input"
    assert output =~ "regex/string parser"
    assert output =~ "Regex.scan"
  end

  defp fixture_project do
    source = """
    defmodule TraceFixture do
      def run(graph) do
        value = graph
        value
      end
    end
    """

    project_from_source(source)
  end

  defp project_from_source(source) do
    dir = Path.join(System.tmp_dir!(), "reach-trace-fixture-#{System.unique_integer()}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "sample.ex")
    File.write!(path, source)
    on_exit(fn -> File.rm_rf(dir) end)

    Reach.Project.from_sources([path])
  end
end
