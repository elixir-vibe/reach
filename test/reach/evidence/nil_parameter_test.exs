defmodule Reach.Evidence.NilParameterTest do
  use ExUnit.Case, async: true

  alias Reach.Evidence.NilParameter
  alias Reach.Project

  test "records nil call sites and unguarded field uses" do
    facts =
      collect("""
      defmodule NilUse do
        def caller, do: read(nil)
        def read(token), do: token.name
      end
      """)

    assert [fact] = Enum.filter(facts, &(&1.function == :read))
    assert fact.parameter == :token
    assert fact.parameter_index == 0
    assert [%{kind: :nil_argument, line: 2}] = fact.nil_sources
    assert [%{safe?: false, line: 3, operation: operation}] = fact.uses
    assert operation =~ "token.name"
  end

  test "treats a final wildcard clause as a total nil fallback" do
    facts =
      collect("""
      defmodule WildcardFallback do
        def caller, do: consume(nil)
        def consume(%{next: next}), do: consume(next)
        def consume(_), do: :done
      end
      """)

    assert [%{uses: []}] = Enum.filter(facts, &(&1.function == :consume))
  end

  test "uses CFG dominance for positive and reversed nil guards" do
    facts =
      collect("""
      defmodule DominatedUse do
        def caller do
          guarded(nil, 429)
          reversed(nil)
        end

        def guarded(token, status) do
          if status == 429 and not is_nil(token), do: token.name
        end

        def reversed(token) do
          if is_nil(token), do: :missing, else: token.name
        end
      end
      """)

    for function <- [:guarded, :reversed] do
      fact = Enum.find(facts, &(&1.function == function))
      assert [%{safe?: true, dominating_guards: [_ | _]}] = fact.uses
    end
  end

  test "recognizes clause patterns and prior total nil clauses" do
    facts =
      collect("""
      defmodule ClauseGuards do
        def caller do
          explicit(nil)
          patterned(nil)
        end

        def explicit(nil), do: :missing
        def explicit(token), do: token.name

        def patterned(%{name: _} = token), do: token.name
      end
      """)

    explicit = Enum.find(facts, &(&1.function == :explicit))
    assert [%{safe?: true}] = explicit.uses

    patterned = Enum.find(facts, &(&1.function == :patterned))
    assert [%{safe?: true}] = patterned.uses
  end

  test "recognizes matching nil clauses, short-circuit guards, and shadowed callback parameters" do
    facts =
      collect("""
      defmodule ContextualGuards do
        def caller do
          sorted(nil, :path)
          short(nil)
          callback(nil)
        end

        def sorted(nil, :path), do: ""
        def sorted(nil, :line), do: 0
        def sorted(value, :path), do: Map.get(value, :path)
        def sorted(value, :line), do: Map.get(value, :line)

        def short(value), do: value && value.name

        def callback(value) do
          Enum.map([], fn value -> value.name end)
          value
        end
      end
      """)

    sorted = Enum.find(facts, &(&1.function == :sorted))
    short = Enum.find(facts, &(&1.function == :short))
    callback = Enum.find(facts, &(&1.function == :callback))

    assert sorted.uses != []
    assert Enum.all?(sorted.uses, & &1.safe?)
    assert [%{safe?: true}] = short.uses
    assert callback.uses == []
  end

  test "scopes literal nil calls to matching multi-parameter clauses" do
    facts =
      collect("""
      defmodule CallContext do
        def caller, do: route(:missing, nil)
        def route(:missing, nil), do: :missing
        def route(:loaded, value), do: value.name
      end
      """)

    fact = Enum.find(facts, &(&1.function == :route))
    assert fact.uses == []
  end

  test "keeps dynamic call arguments conservative across dispatch clauses" do
    facts =
      collect("""
      defmodule DynamicCallContext do
        def caller(kind), do: route(kind, nil)
        def route(:missing, nil), do: :missing
        def route(:loaded, value), do: value.name
      end
      """)

    fact = Enum.find(facts, &(&1.function == :route))
    assert [%{safe?: false, line: 4}] = fact.uses
  end

  test "filters nil sources that cannot reach a short-circuit use" do
    facts =
      collect("""
      defmodule SourceFeasibility do
        def safe_caller, do: safe(nil)
        def unsafe_caller, do: unsafe(nil, true)

        def safe(value, check? \\\\ false) do
          check? && Map.get(value, :id)
        end

        def unsafe(value, check? \\\\ false) do
          check? && Map.get(value, :id)
        end

        def default_safe(value \\\\ nil, check? \\\\ false) do
          check? && Map.get(value, :id)
        end

        def safe_branch_caller, do: safe_branch(nil, 200)
        def unsafe_branch_caller, do: unsafe_branch(nil, 429)

        def safe_branch(value, status) do
          if status == 429, do: Map.get(value, :id)
        end

        def unsafe_branch(value, status) do
          if status == 429, do: Map.get(value, :id)
        end
      end
      """)

    safe = Enum.find(facts, &(&1.function == :safe))
    unsafe = Enum.find(facts, &(&1.function == :unsafe))
    default_safe = Enum.find(facts, &(&1.function == :default_safe))
    safe_branch = Enum.find(facts, &(&1.function == :safe_branch))
    unsafe_branch = Enum.find(facts, &(&1.function == :unsafe_branch))

    assert default_safe.uses == []
    assert safe.uses == []
    assert safe_branch.uses == []
    assert [%{safe?: false}] = unsafe.uses
    assert [%{safe?: false}] = unsafe_branch.uses
  end

  test "keeps conditional compilation definitions isolated" do
    facts =
      collect("""
      defmodule IsolatedDefinitions do
        if System.get_env("FEATURE") do
          def enabled(nil), do: :missing
          def enabled(value), do: value.name
        else
          def enabled(_value), do: :disabled
        end
      end
      """)

    assert Enum.all?(facts, fn fact -> Enum.all?(fact.uses, & &1.safe?) end)
  end

  test "stops parameter provenance after rebinding while retaining uses in the right-hand side" do
    facts =
      collect("""
      defmodule ReboundParameter do
        def normalized(options \\\\ nil) do
          options = options || %{id: 1}
          options.id
        end

        def strict_rhs(options \\\\ nil) do
          options = Map.fetch!(options, :nested)
          options.id
        end
      end
      """)

    normalized = Enum.find(facts, &(&1.function == :normalized))
    strict_rhs = Enum.find(facts, &(&1.function == :strict_rhs))

    assert normalized.uses == []
    assert [%{safe?: false, target: {Map, :fetch!, 2}}] = strict_rhs.uses
  end

  test "recognizes cond guards, companion defaults, guarded nil clauses, and static modules" do
    facts =
      collect("""
      defmodule AdditionalNilGuards do
        def cond_guard(options \\\\ nil) do
          cond do
            is_map(options) -> options.id
            true -> nil
          end
        end

        def companion_default(metadata \\\\ nil, cursor \\\\ nil) do
          case cursor do
            :next -> metadata.id
            _other -> nil
          end
        end

        def guarded_caller, do: guarded_nil(nil)
        def guarded_nil(value) when is_nil(value), do: :missing
        def guarded_nil(value) when is_atom(value), do: value.render()

        def static_module(ets \\\\ nil), do: :ets.new(:nil_parameter_test, [])
      end
      """)

    for function <- [:cond_guard, :companion_default, :guarded_nil, :static_module] do
      fact = Enum.find(facts, &(&1.function == function))
      assert Enum.all?(fact.uses, & &1.safe?)
    end
  end

  test "tracks unless paths, with bindings, repeated dispatch, and default wrappers precisely" do
    facts =
      collect("""
      defmodule AdditionalNilFlow do
        def unless_guard(options \\\\ nil),
          do: unless(is_nil(options), do: Map.get(options, :id))

        def with_binding(options \\\\ nil) do
          with {:ok, options} <- normalize(options) do
            Map.get(options, :id)
          end
        end

        def normalize(options), do: {:ok, options || %{id: 1}}

        def transition(same, same), do: same
        def transition(nil, new), do: consume(new)
        def transition(_old, nil), do: nil
        def consume(%{id: id}), do: id

        def wrapper, do: request(:pool, [], Handler, nil)

        def request(pool, headers \\\\ [], body \\\\ "", module, init) do
          {pool, headers, body, module.handle(init)}
        end
      end
      """)

    for function <- [:unless_guard, :with_binding, :transition] do
      fact = Enum.find(facts, &(&1.function == function))
      assert is_nil(fact) or Enum.all?(fact.uses, & &1.safe?)
    end

    refute Enum.any?(facts, &(&1.function == :request and &1.parameter == :module))
  end

  test "treats calls into shape-restricted functions as strict uses" do
    facts =
      collect("""
      defmodule StrictCallee do
        def caller, do: forward(nil)
        def forward(token), do: consume(token)
        def consume(%{id: id}), do: id
      end
      """)

    fact = Enum.find(facts, &(&1.function == :forward))
    assert [%{safe?: false, target: {StrictCallee, :consume, 1}}] = fact.uses
  end

  test "propagates strict requirements through default-arity wrappers" do
    facts =
      collect("""
      defmodule DefaultArityCallee do
        def caller, do: forward(nil)
        def forward(token), do: consume(token)

        def consume(token, option \\\\ nil)
        def consume(%{id: id}, _option), do: id
      end
      """)

    fact = Enum.find(facts, &(&1.function == :forward))
    assert [%{safe?: false, target: {DefaultArityCallee, :consume, 2}}] = fact.uses
  end

  test "records nil defaults and strict Map uses" do
    facts =
      collect("""
      defmodule NilDefault do
        def read(options \\\\ nil), do: Map.get(options, :name)
      end
      """)

    fact = Enum.find(facts, &(&1.function == :read))
    assert [%{kind: :nil_default}] = fact.nil_sources
    assert [%{safe?: false, target: {Map, :get, 2}}] = fact.uses
  end

  test "supports functions without module metadata" do
    facts =
      collect(
        """
        defmodule ModulelessNilDefault do
          def read(options \\\\ nil), do: Map.get(options, :name)
        end
        """,
        without_module: :read
      )

    assert [%{module: nil, function: :read}] = facts
  end

  defp collect(source, opts \\ []) do
    path =
      Path.join(System.tmp_dir!(), "reach-nil-parameter-#{System.unique_integer([:positive])}.ex")

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)

    project = Project.from_sources([path])

    project =
      case opts[:without_module] do
        nil -> project
        name -> delete_function_module(project, name)
      end

    NilParameter.collect_project(project)
  end

  defp delete_function_module(project, name) do
    {id, _function} =
      Enum.find(project.nodes, fn {_id, node} ->
        node.type == :function_def and node.meta[:name] == name
      end)

    nodes =
      Map.update!(project.nodes, id, fn function ->
        %{function | meta: Map.delete(function.meta, :module)}
      end)

    %{project | nodes: nodes}
  end
end
