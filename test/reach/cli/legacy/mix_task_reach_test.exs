defmodule Mix.Tasks.ReachTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Mix.Tasks.Reach, as: ReachTask

  @output_dir Path.join(System.tmp_dir!(), "reach_task_test")

  setup do
    File.rm_rf!(@output_dir)
    on_exit(fn -> File.rm_rf!(@output_dir) end)
    :ok
  end

  test "prints help without analyzing" do
    output = capture_io(fn -> ReachTask.run(["--help"]) end)

    assert output =~ "mix reach"
    assert output =~ "--format"
    refute output =~ "Analyzing"
    refute File.exists?(Path.join("reach_report", "index.html"))
  end

  test "generates HTML report for a file" do
    path =
      write_tmp_file("test_mod.ex", """
      defmodule TaskTestMod do
        def hello(name), do: IO.puts(name)
      end
      """)

    ReachTask.run([path, "--output", @output_dir, "--no-open"])

    html_path = Path.join(@output_dir, "index.html")
    assert File.exists?(html_path)

    content = File.read!(html_path)
    assert content =~ "graphData"
  end

  test "generates DOT output" do
    path =
      write_tmp_file("dot_mod.ex", """
      defmodule DotTestMod do
        def x, do: 1
      end
      """)

    ReachTask.run([path, "--format", "dot", "--output", @output_dir])

    dot_path = Path.join(@output_dir, "reach.dot")
    assert File.exists?(dot_path)
    assert File.read!(dot_path) =~ "digraph"
  end

  test "generates JSON output" do
    path =
      write_tmp_file("json_mod.ex", """
      defmodule JsonTestMod do
        def f(x), do: g(x)
      end
      """)

    ReachTask.run([path, "--format", "json", "--output", @output_dir])

    json_path = Path.join(@output_dir, "reach.json")
    assert File.exists?(json_path)
    assert {:ok, data} = Jason.decode(File.read!(json_path))
    assert is_list(data["control_flow"])
    assert is_map(data["call_graph"])
  end

  defp write_tmp_file(name, content) do
    dir = Path.join(System.tmp_dir!(), "reach_task_src")
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end
end
