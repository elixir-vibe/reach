defmodule Reach.Smell.ContractClassificationTest do
  # Persisted dependency fixtures mutate the VM-global code path and load/purge code.
  use ExUnit.Case, async: false

  alias Reach.Smell.Checks.{BehaviourCandidate, FixedShapeMap}

  defp project(source, compile? \\ false) do
    path = Path.join(System.tmp_dir!(), "reach_contract_#{System.unique_integer([:positive])}.ex")
    File.write!(path, source)
    compiled = if compile?, do: Code.compile_file(path), else: []

    on_exit(fn ->
      File.rm!(path)

      for {module, _bytecode} <- compiled do
        :code.purge(module)
        :code.delete(module)
      end
    end)

    Reach.Project.from_sources([path])
  end

  defp providers(body) do
    for name <- ["First", "Second", "Third"], into: "" do
      "defmodule ContractFixture.#{name} do\n#{body}\nend\n"
    end
  end

  defp persisted_dependency(source, unload? \\ true) do
    directory =
      Path.join(System.tmp_dir!(), "reach_contract_beams_#{System.unique_integer([:positive])}")

    File.mkdir!(directory)
    path = Path.join(directory, "contract.ex")
    File.write!(path, source)
    compiled = Code.compile_file(path)

    for {module, bytecode} <- compiled do
      File.write!(Path.join(directory, "#{module}.beam"), bytecode)

      if unload? do
        :code.delete(module)
        :code.purge(module)
      end
    end

    true = :code.add_patha(String.to_charlist(directory))

    on_exit(fn ->
      :code.del_path(String.to_charlist(directory))

      for {module, _bytecode} <- compiled do
        :code.delete(module)
        :code.purge(module)
      end

      File.rm_rf!(directory)
    end)
  end

  test "map patterns, updates, specs and quoted syntax do not count as constructed records" do
    source = """
    defmodule ShapeContexts do
      @type record :: %{id: integer(), kind: atom(), target: term()}
      @spec read(%{id: integer(), kind: atom(), target: term()}) :: term()
      def read(%{id: _, kind: _, target: _} = value) do
        %{id: 1, kind: :literal, target: nil} = value
        case value do
          %{id: id, kind: kind, target: target} -> {id, kind, target}
        end
        with %{id: _, kind: _, target: _} <- value do
          value
        end
        for %{id: _, kind: _, target: _} <- [value], do: value
        Enum.map([value], fn %{id: _, kind: _, target: _} -> value end)
        %{value | id: 2, kind: :updated, target: nil}
      end
      def update_a(value), do: %{value | id: 1, kind: :a, target: nil}
      def update_b(value), do: %{value | id: 2, kind: :b, target: nil}
      def syntax do
        quote do
          %{id: 1, kind: :quoted, target: nil}
          %{id: 2, kind: :quoted, target: nil}
          %{id: 3, kind: :quoted, target: nil}
        end
      end
    end
    """

    assert FixedShapeMap.run(project(source)) == []
  end

  test "repeated constructions remain evidence even alongside pattern matching and updates" do
    source = """
    defmodule ConstructedShapes do
      def first do
        %{id: id, kind: _, target: _} = %{id: 1, kind: :a, target: nil}
        id
      end
      def second(value) do
        case value do
          %{id: id, kind: _, target: _} -> %{id: id, kind: :b, target: nil}
        end
      end
      def third do
        Enum.map([1], fn id -> %{id: id, kind: :c, target: nil} end)
      end
      def update(value), do: %{value | id: 4, kind: :d, target: nil}
    end
    """

    assert [finding] = FixedShapeMap.run(project(source))
    assert finding.keys == ["id", "kind", "target"]
    assert finding.occurrences == 3
    assert length(finding.evidence) == 3
  end

  test "condition expressions still construct maps" do
    source = """
    defmodule ConditionShapes do
      def choose do
        cond do
          %{id: 1, kind: :a, target: nil} == %{} -> :first
          %{id: 2, kind: :b, target: nil} == %{} -> :second
          %{id: 3, kind: :c, target: nil} == %{} -> :third
        end
      end
    end
    """

    assert [%{occurrences: 3}] = FixedShapeMap.run(project(source))
  end

  test "Supervisor child specs have an existing contract but identical literals elsewhere do not" do
    source =
      providers("""
      def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
      def record(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
      """)

    assert [finding] = FixedShapeMap.run(project(source))
    assert finding.keys == ["id", "restart", "start"]
    assert finding.occurrences == 3
  end

  test "non-contract fields in child_spec are not exempted" do
    source =
      providers("""
      def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, domain: :custom}
      """)

    assert [%{keys: ["domain", "id", "start"], occurrences: 3}] =
             FixedShapeMap.run(project(source))
  end

  test "only returned child specs receive the Supervisor contract exemption" do
    source =
      providers("""
      def child_spec(opts) do
        record = %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
        notify(record)
        %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, shutdown: 5000}
      end
      """)

    assert [%{keys: ["id", "restart", "start"], occurrences: 3}] =
             FixedShapeMap.run(project(source))
  end

  test "only callbacks covered by a declared source behaviour leave the candidate API" do
    contract = """
    defmodule SourceContract do
      @callback init(term()) :: term()
      @callback render(term()) :: term()
      @callback handle_event(term(), term(), term()) :: term()
    end
    """

    implementations =
      providers("""
      alias SourceContract, as: Contract
      @behaviour Contract
      def init(value), do: value
      def render(value), do: value
      def handle_event(event, params, state), do: {event, params, state}
      def extra(value), do: value
      """)

    assert BehaviourCandidate.run(project(contract <> implementations)) == []
  end

  test "three shared custom APIs remain candidates in modules with behaviours" do
    contract = """
    defmodule CustomContract do
      @callback init(term()) :: term()
    end
    """

    implementations =
      providers("""
      @behaviour CustomContract
      def init(value), do: value
      def fetch(value), do: value
      def normalize(value), do: value
      def store(value), do: value
      """)

    assert [finding] = BehaviourCandidate.run(project(contract <> implementations))
    assert finding.callbacks == ["fetch/1", "normalize/1", "store/1"]
    assert finding.occurrences == 3
  end

  test "source behaviour contracts resolve grouped aliases" do
    contract = """
    defmodule Grouped.Contracts.Provider do
      @callback fetch(term()) :: term()
      @callback normalize(term()) :: term()
      @callback store(term()) :: term()
    end
    """

    implementations =
      providers("""
      alias Grouped.Contracts.{Provider}
      @behaviour Provider
      def fetch(value), do: value
      def normalize(value), do: value
      def store(value), do: value
      """)

    assert BehaviourCandidate.run(project(contract <> implementations)) == []
  end

  test "matching names at different arities are not covered callbacks" do
    contract = """
    defmodule ArityContract do
      @callback fetch(term()) :: term()
      @callback normalize(term()) :: term()
      @callback store(term()) :: term()
    end
    """

    implementations =
      providers("""
      @behaviour ArityContract
      def fetch(a, b), do: {a, b}
      def normalize(a, b), do: {a, b}
      def store(a, b), do: {a, b}
      """)

    assert [%{callbacks: ["fetch/2", "normalize/2", "store/2"]}] =
             BehaviourCandidate.run(project(contract <> implementations))
  end

  test "unknown behaviours do not authorize guessing callbacks" do
    source =
      providers("""
      @behaviour ContractFixture.Unavailable
      def init(value), do: value
      def fetch(value), do: value
      def normalize(value), do: value
      """)

    assert [%{callbacks: ["fetch/1", "init/1", "normalize/1"]}] =
             BehaviourCandidate.run(project(source))
  end

  test "macro-injected contracts are read from the compiled consumer without library name rules" do
    suffix = System.unique_integer([:positive])
    contract = "PersistedInjectedContract#{suffix}"

    persisted_dependency("""
    defmodule #{contract} do
      @compile :debug_info
      @callback init(term()) :: term()
      @callback render(term()) :: term()
      @callback handle_event(term(), term(), term()) :: term()
      defmacro __using__(_opts) do
        quote do
          @behaviour #{contract}
        end
      end
    end
    """)

    source =
      for name <- ["First", "Second", "Third"], into: "" do
        """
        defmodule CompiledContractFixture.#{name}#{suffix} do
          use #{contract}
          def init(value), do: value
          def render(value), do: value
          def handle_event(event, params, state), do: {event, params, state}
          def custom(value), do: value
        end
        """
      end

    assert BehaviourCandidate.run(project(source, true)) == []
  end

  test "unloaded behaviour metadata resolves callbacks without executing its on_load hook" do
    suffix = System.unique_integer([:positive])
    contract = Module.concat(["UnloadedContract#{suffix}"])
    marker = Path.join(System.tmp_dir!(), "reach_contract_on_load_#{suffix}")
    on_exit(fn -> File.rm(marker) end)

    persisted_dependency("""
    defmodule #{inspect(contract)} do
      @compile :debug_info
      @on_load :notify
      @callback init(term()) :: term()
      def notify, do: File.write!(#{inspect(marker)}, "loaded")
    end
    """)

    # Compilation intentionally loaded the fixture once; analysis must not load it.
    assert File.read!(marker) == "loaded"
    File.rm!(marker)
    assert :code.is_loaded(contract) == false

    source =
      providers("""
      @behaviour #{inspect(contract)}
      def init(value), do: value
      def fetch(value), do: value
      def normalize(value), do: value
      def store(value), do: value
      """)

    assert [%{callbacks: ["fetch/1", "normalize/1", "store/1"], occurrences: 3}] =
             BehaviourCandidate.run(project(source))

    assert :code.is_loaded(contract) == false
    refute File.exists?(marker)
  end

  test "persisted callback metadata remains available for a behaviour compiled in memory" do
    contract = Module.concat(["InMemoryContract#{System.unique_integer([:positive])}"])

    persisted_dependency(
      """
      defmodule #{inspect(contract)} do
        @compile :debug_info
        @callback init(term()) :: term()
      end
      """,
      false
    )

    source =
      providers("""
      @behaviour #{inspect(contract)}
      def init(value), do: value
      def fetch(value), do: value
      def normalize(value), do: value
      def store(value), do: value
      """)

    assert [%{callbacks: ["fetch/1", "normalize/1", "store/1"], occurrences: 3}] =
             BehaviourCandidate.run(project(source))
  end

  test "GenServer startup facades including project-local delegation are existing OTP contracts" do
    source = """
    defmodule StartupDelegate do
      def start(module, opts) do
        opts = Keyword.put_new(opts, :name, module)
        case Keyword.get(opts, :name) do
          nil -> GenServer.start_link(module, opts)
          name -> GenServer.start_link(module, opts, name: name)
        end
      end
    end
    """

    source =
      source <>
        providers("""
        @behaviour GenServer
        def init(opts), do: {:ok, opts}
        def start_link(opts), do: StartupDelegate.start(__MODULE__, opts)
        def refresh(server), do: GenServer.cast(server, :refresh)
        def status(server), do: GenServer.call(server, :status)
        """)

    assert BehaviourCandidate.run(project(source)) == []
  end

  test "custom start_link is retained without OTP delegation or without a GenServer contract" do
    custom =
      providers("""
      @behaviour GenServer
      def init(opts), do: {:ok, opts}
      def start_link(opts), do: {:configured, opts}
      def refresh(value), do: value
      def status(value), do: value
      """)

    assert [%{callbacks: ["refresh/1", "start_link/1", "status/1"]}] =
             BehaviourCandidate.run(project(custom))

    no_contract =
      providers("""
      def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
      def refresh(value), do: value
      def status(value), do: value
      """)

    assert [%{callbacks: ["refresh/1", "start_link/1", "status/1"]}] =
             BehaviourCandidate.run(project(no_contract))
  end

  test "startup-like calls must return a server started with the consumer's own module" do
    delegate = """
    defmodule OtherStartupDelegate do
      def start(_module, opts), do: GenServer.start_link(__MODULE__, opts)
    end
    """

    source =
      delegate <>
        providers("""
        @behaviour GenServer
        def init(opts), do: {:ok, opts}
        def start_link(opts), do: OtherStartupDelegate.start(__MODULE__, opts)
        def refresh(value), do: value
        def status(value), do: value
        """)

    assert [%{callbacks: ["refresh/1", "start_link/1", "status/1"]}] =
             BehaviourCandidate.run(project(source))

    discards_result =
      providers("""
      @behaviour GenServer
      def init(opts), do: {:ok, opts}
      def start_link(opts) do
        GenServer.start_link(__MODULE__, opts)
        {:configured, opts}
      end
      def refresh(value), do: value
      def status(value), do: value
      """)

    assert [%{callbacks: ["refresh/1", "start_link/1", "status/1"]}] =
             BehaviourCandidate.run(project(discards_result))
  end

  test "a startup delegate cannot rebind the forwarded module and retain the contract exemption" do
    delegate = """
    defmodule RebindingStartupDelegate do
      def start(module, opts) do
        module = OtherServer
        GenServer.start_link(module, opts)
      end
    end
    """

    source =
      delegate <>
        providers("""
        @behaviour GenServer
        def init(opts), do: {:ok, opts}
        def start_link(opts), do: RebindingStartupDelegate.start(__MODULE__, opts)
        def refresh(value), do: value
        def status(value), do: value
        """)

    assert [%{callbacks: ["refresh/1", "start_link/1", "status/1"]}] =
             BehaviourCandidate.run(project(source))
  end
end
