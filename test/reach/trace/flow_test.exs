defmodule Reach.Trace.FlowTest do
  use ExUnit.Case, async: true

  alias Reach.Trace.Flow

  test "regex-on-structured traces static structured paths and structure-shaped fallback regexes" do
    project =
      project_from_source("""
      defmodule StructuredParser do
        def xml do
          source = File.read!("priv/items.xml")
          Regex.scan(~r|<item>(.*?)</item>|, source)
        end

        def dynamic(path) do
          source = File.read!(path)
          source =~ ~r/defmodule\\s+/
        end

        def html do
          source = File.read!("priv/index.html")
          String.split(source, ~r/<[^>]+>/)
        end

        def plain_text do
          source = File.read!("README.txt")
          Regex.scan(~r/heading/, source)
        end

        def non_regex_split do
          source = File.read!("priv/items.xml")
          String.split(source, "<item>")
        end
      end
      """)

    assert {:ok, result} = Flow.analyze_preset(project, "regex-on-structured", 50)
    assert result.from == "structured file input"
    assert result.to == "regex/string parser"
    assert length(result.paths) == 3

    assert result.paths |> Enum.map(& &1.sink.meta[:function]) |> Enum.sort() == [
             :=~,
             :scan,
             :split
           ]

    refute Enum.any?(result.paths, fn path ->
             match?([%{meta: %{value: "README.txt"}}], path.source.children)
           end)
  end

  test "returns an explicit error for unknown presets" do
    project = project_from_source("defmodule Empty do\nend\n")
    assert {:error, :unknown_preset} = Flow.analyze_preset(project, "unknown", 50)
  end

  defp project_from_source(source) do
    dir = Path.join(System.tmp_dir!(), "reach-trace-flow-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "sample.ex")
    File.write!(path, source)
    on_exit(fn -> File.rm_rf(dir) end)
    Reach.Project.from_sources([path])
  end
end
