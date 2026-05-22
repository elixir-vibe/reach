defmodule Reach.Check.ArchitecturePolicyTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Reach.Check.Architecture
  alias Reach.CLI.Commands.Check

  test "reach.check validates an empty architecture policy" do
    project = architecture_project()
    with_reach_config(~S([layers: [cli: "Fixture.CLI.*", core: "Fixture.Core.*"]]))

    output = capture_io(fn -> Check.run(arch: true, format: "json", project: project) end)

    assert {:ok, data} = Jason.decode(output)
    assert data["status"] == "ok"
    assert data["violations"] == []
  end

  test "reach.check accepts grouped architecture policy" do
    project = architecture_project()

    with_reach_config(~S([
      layers: [cli: "Fixture.CLI.*", core: "Fixture.Core.*"],
      deps: [forbidden: []],
      calls: [forbidden: []],
      effects: [allowed: []],
      boundaries: [public: [], internal: [], internal_callers: []],
      tests: [hints: []],
      source: [forbidden_modules: [], forbidden_files: []]
    ]))

    output = capture_io(fn -> Check.run(arch: true, format: "json", project: project) end)

    assert {:ok, data} = Jason.decode(output)
    assert data["status"] == "ok"
    assert data["violations"] == []
  end

  test "reach.check runs each requested check mode" do
    path = dead_code_fixture()
    project = Reach.Project.from_sources([path])
    with_reach_config(~S([layers: [fixture: "DeadCodeFixture"]]))

    output =
      capture_io(fn -> Check.run([arch: true, dead_code: true, project: project], [path]) end)

    assert output =~ "Architecture Policy"
    assert output =~ "Dead Code"
  end

  test "reach.check rejects multiple modes for json output" do
    with_reach_config(~S([layers: [cli: "Mix.Tasks.*", core: "Reach.*"]]))

    assert_raise Mix.Error, ~r/JSON output supports one reach.check mode/, fn ->
      Check.run(arch: true, smells: true, format: "json")
    end
  end

  test "reach.check --smells --strict fails when findings are present" do
    path = smell_fixture("def run(items), do: items |> Enum.reverse() |> Enum.reverse()")
    with_reach_config(~S([]))

    assert_raise Mix.Error, ~r/Smell check failed: \d+ finding\(s\)/, fn ->
      capture_io(fn -> Check.run([smells: true, strict: true], [path]) end)
    end
  end

  test "reach.check --smells honors strict config" do
    path = smell_fixture("def run(items), do: items |> Enum.reverse() |> Enum.reverse()")
    with_reach_config(~S([smells: [strict: true]]))

    assert_raise Mix.Error, ~r/Smell check failed: \d+ finding\(s\)/, fn ->
      capture_io(fn -> Check.run([smells: true], [path]) end)
    end
  end

  test "reach.check reports architecture config errors" do
    with_reach_config("[unknown: true, layers: :bad]")

    assert_raise Mix.Error, ~r/Architecture policy failed/, fn ->
      capture_io(fn -> Check.run(arch: true, format: "json") end)
    end
  end

  test "reach.check reports grouped architecture config errors" do
    with_reach_config("[deps: [forbidden: :bad, unknown: []]]")

    assert_raise Mix.Error, ~r/Architecture policy failed/, fn ->
      capture_io(fn -> Check.run(arch: true, format: "json") end)
    end
  end

  test "reach.check validates forbidden call config shape" do
    with_reach_config(~S([forbidden_calls: :bad]))

    assert_raise Mix.Error, ~r/Architecture policy failed/, fn ->
      capture_io(fn -> Check.run(arch: true, format: "json") end)
    end
  end

  test "reach.check reports forbidden call violations" do
    project = architecture_project()

    with_reach_config(~S([forbidden_calls: [{"Fixture.CLI.Command", ["Fixture.Config.read"]}]]))

    assert_raise Mix.Error, ~r/Architecture policy failed/, fn ->
      capture_io(fn -> Check.run(arch: true, format: "json", project: project) end)
    end
  end

  test "reach.check reports grouped forbidden call violations" do
    project = architecture_project()

    with_reach_config(
      ~S([calls: [forbidden: [{"Fixture.CLI.Command", ["Fixture.Config.read"]}]]])
    )

    assert_raise Mix.Error, ~r/Architecture policy failed/, fn ->
      capture_io(fn -> Check.run(arch: true, format: "json", project: project) end)
    end
  end

  test "reach.check reports forbidden source violations" do
    project = architecture_project()

    with_reach_config(~S([
      source: [
        forbidden_modules: ["Fixture.CLI.Command"],
        forbidden_files: ["**/command.ex"]
      ]
    ]))

    assert_raise Mix.Error, ~r/Architecture policy failed/, fn ->
      capture_io(fn -> Check.run(arch: true, format: "json", project: project) end)
    end
  end

  test "reach.check allows forbidden call exceptions" do
    project = architecture_project()

    with_reach_config(
      ~S([forbidden_calls: [{"Fixture.CLI.Command", ["Fixture.Config.read"], except: ["Fixture.CLI.Command"]}]])
    )

    output = capture_io(fn -> Check.run(arch: true, format: "json", project: project) end)

    assert {:ok, data} = Jason.decode(output)
    assert data["status"] == "ok"
    assert data["violations"] == []
  end

  test "reach.check reports layer coverage violations" do
    project = architecture_project()

    with_reach_config(~S([
      layers: [cli: "Fixture.CLI.*", duplicate: "Fixture.CLI.Command"],
      checks: [
        layer_coverage: [
          require_all_modules: true,
          forbid_multiple_matches: true,
          ignore: ["Fixture.Internal.*"]
        ]
      ]
    ]))

    assert_raise Mix.Error, ~r/Architecture policy failed/, fn ->
      output = capture_io(fn -> Check.run(arch: true, format: "json", project: project) end)
      assert {:ok, data} = Jason.decode(output)
      assert Enum.any?(data["violations"], &(&1["type"] == "missing_layer"))
      assert Enum.any?(data["violations"], &(&1["type"] == "multiple_layers"))
    end
  end

  test "reach.check reports allowlist dependency violations" do
    project = architecture_project()

    with_reach_config(~S([
      layers: [cli: "Fixture.CLI.*", core: "Fixture.Core.*", config: "Fixture.Config"],
      deps: [mode: :allowlist, allowed: [cli: [:core], core: [], config: []]]
    ]))

    assert_raise Mix.Error, ~r/Architecture policy failed/, fn ->
      capture_io(fn -> Check.run(arch: true, format: "json", project: project) end)
    end
  end

  test "reach.check reports layer effect policy violations" do
    dir = Path.join(System.tmp_dir!(), "reach-effect-layer-fixture-#{System.unique_integer()}")
    File.mkdir_p!(dir)

    write_fixture(dir, "domain.ex", ~S'''
    defmodule EffectLayer.Domain do
      def run, do: IO.puts("side effect")
    end
    ''')

    on_exit(fn -> File.rm_rf(dir) end)

    project = Reach.Project.from_sources(Path.wildcard(Path.join(dir, "*.ex")))

    with_reach_config(~S([
      layers: [domain: "EffectLayer.Domain"],
      effects: [by_layer: [domain: [:pure]]]
    ]))

    assert_raise Mix.Error, ~r/Architecture policy failed/, fn ->
      capture_io(fn -> Check.run(arch: true, format: "json", project: project) end)
    end
  end

  test "reach.check allows forbidden dependency exceptions" do
    project = architecture_project()

    with_reach_config(~S([
      layers: [cli: "Fixture.CLI.*", config: "Fixture.Config"],
      deps: [forbidden: [{:cli, :config, except: ["Fixture.CLI.Command"]}]]
    ]))

    output = capture_io(fn -> Check.run(arch: true, format: "json", project: project) end)

    assert {:ok, data} = Jason.decode(output)
    assert data["status"] == "ok"
    assert data["violations"] == []
  end

  test "architecture layer cycle violations include concrete edge witnesses" do
    dir = Path.join(System.tmp_dir!(), "reach-cycle-fixture-#{System.unique_integer()}")
    File.mkdir_p!(dir)

    a_path =
      write_fixture(dir, "a.ex", ~S'''
      defmodule Cycle.A do
        def run, do: Cycle.B.run()
      end
      ''')

    write_fixture(dir, "b.ex", ~S'''
    defmodule Cycle.B do
      def run, do: Cycle.A.run()
    end
    ''')

    on_exit(fn -> File.rm_rf(dir) end)

    project = Reach.Project.from_sources(Path.wildcard(Path.join(dir, "*.ex")))
    config = [layers: [a: "Cycle.A", b: "Cycle.B"]]

    violations = Architecture.violations(project, config)
    cycle = Enum.find(violations, &(&1.type == :layer_cycle))

    assert cycle.edges != []
    assert Enum.any?(cycle.edges, &(&1.file == a_path))
  end

  test "reach.check reports public and internal boundary violations" do
    project = architecture_project()

    with_reach_config(~S([
        public_api: ["Fixture"],
        internal: ["Fixture.Internal.*"],
        internal_callers: [{"Fixture.Internal.*", ["Fixture.Core.Allowed"]}]
      ]))

    assert_raise Mix.Error, ~r/Architecture policy failed/, fn ->
      capture_io(fn -> Check.run(arch: true, format: "json", project: project) end)
    end
  end

  test "evidence providers stay reusable and do not emit smell findings" do
    evidence_sources = Path.wildcard("lib/reach/evidence/**/*.ex")

    refute evidence_sources == []

    for source <- evidence_sources do
      content = File.read!(source)
      refute content =~ "Reach.Smell.Finding"
      refute content =~ "Finding.new"
      refute content =~ "Reach.CLI."
    end
  end

  test "legacy clone analysis namespace is not reintroduced" do
    modules = :reach |> Application.spec(:modules) |> List.wrap()

    refute Enum.any?(modules, &(Module.split(&1) |> Enum.take(2) == ["Reach", "CloneAnalysis"]))
  end

  test "Poison has its own plugin instead of using generic JSON plugin" do
    assert Code.ensure_loaded?(Reach.Plugins.Poison)
    refute Code.ensure_loaded?(Reach.Plugins.JSON)
    assert Reach.Plugin.classify_effect([Reach.Plugins.Poison], poison_call_node()) == :pure
  end

  defp architecture_project do
    dir = Path.join(System.tmp_dir!(), "reach-arch-fixture-#{System.unique_integer()}")
    File.mkdir_p!(dir)

    write_fixture(dir, "config.ex", ~S'''
    defmodule Fixture.Config do
      def read, do: :ok
    end
    ''')

    write_fixture(dir, "service.ex", ~S'''
    defmodule Fixture.Core.Service do
      def run, do: :ok
    end
    ''')

    write_fixture(dir, "secret.ex", ~S'''
    defmodule Fixture.Internal.Secret do
      def ping, do: :pong
    end
    ''')

    command_path =
      write_fixture(dir, "command.ex", ~S'''
      defmodule Fixture.CLI.Command do
        def run do
          Fixture.Config.read()
          Fixture.Core.Service.run()
          Fixture.Internal.Secret.ping()
        end
      end
      ''')

    on_exit(fn -> File.rm_rf(dir) end)

    dir
    |> Path.join("*.ex")
    |> Path.wildcard()
    |> case do
      [] -> [command_path]
      paths -> paths
    end
    |> Reach.Project.from_sources()
  end

  defp write_fixture(dir, name, source) do
    path = Path.join(dir, name)
    File.write!(path, source)
    path
  end

  defp dead_code_fixture do
    dir = Path.join(System.tmp_dir!(), "reach-dead-code-fixture-#{System.unique_integer()}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "sample.ex")

    File.write!(path, """
    defmodule DeadCodeFixture do
      def run do
        String.downcase("VALUE")
        :ok
      end
    end
    """)

    on_exit(fn -> File.rm_rf(dir) end)
    path
  end

  defp smell_fixture(body) do
    dir = Path.join(System.tmp_dir!(), "reach-smell-fixture-#{System.unique_integer()}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "sample.ex")
    File.write!(path, "defmodule ReachSmellFixture do\n  #{body}\nend\n")
    on_exit(fn -> File.rm_rf(dir) end)
    path
  end

  defp poison_call_node do
    %Reach.IR.Node{
      id: "poison",
      type: :call,
      meta: %{module: Poison, function: :encode!, arity: 1},
      children: []
    }
  end

  defp with_reach_config(contents) do
    previous = if File.exists?(".reach.exs"), do: File.read!(".reach.exs")
    File.write!(".reach.exs", contents)

    on_exit(fn ->
      if previous do
        File.write!(".reach.exs", previous)
      else
        File.rm(".reach.exs")
      end
    end)
  end
end
