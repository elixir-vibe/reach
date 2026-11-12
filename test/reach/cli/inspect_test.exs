defmodule Reach.CLI.InspectTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Reach.CLI.Commands.Inspect

  test "reach.inspect preserves call graph rendering option" do
    project = fixture_project()
    output = capture_io(fn -> Inspect.run([call_graph: true, project: project], ["run/1"]) end)

    assert output =~ "run/1"
  end

  test "reach.inspect explains module dependency paths" do
    project = fixture_project()

    output =
      capture_io(fn -> Inspect.run([why: "Demo.Helper", project: project], ["Demo.Main"]) end)

    assert output =~ "module_dependency_path" or output =~ "No path"
    assert output =~ "Demo"
  end

  test "reach.inspect --why reports when no call path exists" do
    project = fixture_project()

    output =
      capture_io(fn ->
        Inspect.run([why: "Demo.Main.run/1", project: project], ["Demo.Helper.clean/1"])
      end)

    assert output =~ "No call_path found."
  end

  defp fixture_project do
    source = """
    defmodule Demo.Helper do
      def clean(value), do: String.trim(value)
    end

    defmodule Demo.Main do
      def run(value), do: Demo.Helper.clean(value)
    end
    """

    dir = Path.join(System.tmp_dir!(), "reach-inspect-fixture-#{System.unique_integer()}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "sample.ex")
    File.write!(path, source)
    on_exit(fn -> File.rm_rf(dir) end)

    Reach.Project.from_sources([path])
  end
end
