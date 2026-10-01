defmodule Reach.SmellTest do
  use ExUnit.Case, async: true

  alias Reach.Check.Smells

  defp run_smell_task(code, config \\ []) do
    path = Path.join(System.tmp_dir!(), "smell_test_#{:erlang.unique_integer([:positive])}.ex")
    File.write!(path, code)
    project = Reach.Project.from_sources([path])
    Smells.run(project, config)
  end

  describe "check registry" do
    test "auto-discovers behaviour modules" do
      checks = Reach.Smell.Registry.checks()

      assert Reach.Smell.Checks.DualKeyAccess in checks
      assert Reach.Smell.Checks.FixedShapeMap in checks
      assert Reach.Smell.Checks.BehaviourCandidate in checks
      assert Reach.Smell.Checks.CollectionIdioms in checks
      assert Reach.Smell.Checks.CloneConsistency in checks
      assert Reach.Smell.Checks.ConfigPhase in checks
      assert Reach.Smell.Checks.PipelineWaste in checks
    end
  end

  describe "Enum.map + List.first detection" do
    test "List.first inside Enum.map callback is a descendant" do
      graph =
        Reach.string_to_graph!("""
        def foo(rows) do
          Enum.map(rows, &List.first/1)
        end
        """)

      all = Reach.nodes(graph)

      map_call =
        Enum.find(
          all,
          &(&1.type == :call and &1.meta[:function] == :map and &1.meta[:module] == Enum)
        )

      first_call =
        Enum.find(
          all,
          &(&1.type == :call and &1.meta[:function] == :first and &1.meta[:module] == List)
        )

      assert map_call
      assert first_call

      descendant_ids = Reach.IR.all_nodes(map_call) |> Enum.map(& &1.id)
      assert first_call.id in descendant_ids
    end

    test "List.first after pipe is NOT a descendant of Enum.map" do
      graph =
        Reach.string_to_graph!("""
        def foo(rows) do
          rows |> Enum.map(&to_string/1) |> List.first()
        end
        """)

      all = Reach.nodes(graph)

      enum_calls =
        all
        |> Enum.filter(fn n ->
          n.type == :call and n.meta[:module] in [Enum, List] and n.source_span != nil
        end)
        |> Enum.sort_by(fn n -> n.source_span[:start_line] end)

      map_call = Enum.find(enum_calls, &(&1.meta[:function] == :map))
      first_call = Enum.find(enum_calls, &(&1.meta[:function] == :first))
      assert map_call && first_call

      descendant_ids = Reach.IR.all_nodes(map_call) |> Enum.map(& &1.id)
      refute first_call.id in descendant_ids
    end
  end

  describe "redundant computation exclusions" do
    test "field access calls are excluded from redundant detection" do
      graph =
        Reach.string_to_graph!("""
        def foo(state) do
          a = state.name
          b = state.name
          {a, b}
        end
        """)

      all = Reach.nodes(graph)

      field_calls =
        Enum.filter(all, fn n ->
          n.type == :call and n.meta[:kind] == :field_access
        end)

      assert length(field_calls) >= 2
    end
  end

  describe "false positive prevention" do
    test "pattern cons operator is not flagged as redundant" do
      findings =
        run_smell_task("""
        defmodule PatternTest do
          def foo(list) do
            case list do
              [a | rest] -> {a, rest}
              [b | tail] -> {b, tail}
            end
          end
        end
        """)

      pipe_findings =
        Enum.filter(findings, fn f ->
          f.kind == :redundant_computation and String.contains?(f.message, "|")
        end)

      assert pipe_findings == []
    end

    test "string interpolation to_string is not flagged" do
      findings =
        run_smell_task("""
        defmodule InterpolationTest do
          def greet(name) do
            header = "Hello \#{name}"
            IO.puts(header)
            footer = "Bye \#{name}"
            IO.puts(footer)
          end
        end
        """)

      to_string_findings =
        Enum.filter(findings, fn f ->
          f.kind == :redundant_computation and String.contains?(f.message, "to_string")
        end)

      assert to_string_findings == []
    end

    test "unrelated Enum.map and List.first are not flagged as eager" do
      findings =
        run_smell_task("""
        defmodule UnrelatedTest do
          def foo(items) do
            mapped = Enum.map(items, &to_string/1)
            first = List.first(other_list())
            {mapped, first}
          end

          defp other_list, do: [1, 2, 3]
        end
        """)

      eager = Enum.filter(findings, &(&1.kind == :eager_pattern))
      assert eager == []
    end

    test "binary pattern size references are not flagged as redundant computation" do
      findings =
        run_smell_task("""
        defmodule BinaryPatternTest do
          def parse(<<count, data::binary-size(count), rest::binary-size(count)>>) do
            {data, rest}
          end
        end
        """)

      size_findings =
        Enum.filter(findings, fn f ->
          f.kind == :redundant_computation and String.contains?(f.message, "size")
        end)

      assert size_findings == []
    end

    test "module references are not flagged as redundant computation" do
      findings =
        run_smell_task("""
        defmodule AliasTest do
          def foo do
            a = SomeModule.call(1)
            b = SomeModule.call(2)
            {a, b}
          end
        end
        """)

      redundant =
        Enum.filter(findings, fn f ->
          f.kind == :redundant_computation and String.contains?(f.message, "__aliases__")
        end)

      assert redundant == []
    end

    test "actual duplicate pure calls are still detected" do
      findings =
        run_smell_task("""
        defmodule DuplicateTest do
          def foo(list) do
            a = Enum.count(list)
            IO.puts(a)
            b = Enum.count(list)
            b
          end
        end
        """)

      redundant = Enum.filter(findings, &(&1.kind == :redundant_computation))
      assert redundant != []
    end

    test "piped Enum.map into List.first IS detected" do
      findings =
        run_smell_task("""
        defmodule PipedEagerTest do
          def foo(items) do
            items |> Enum.map(&to_string/1) |> List.first()
          end
        end
        """)

      eager = Enum.filter(findings, &(&1.kind == :eager_pattern))
      assert eager != []
    end
  end

  describe "collection pipeline smells" do
    test "flags sort then reverse" do
      findings =
        run_smell_task("""
        defmodule SortReverse do
          def f(items), do: items |> Enum.sort() |> Enum.reverse()
        end
        """)

      assert Enum.any?(
               findings,
               &(&1.kind == :eager_pattern and &1.message =~ "sort(enumerable, :desc)")
             )
    end

    test "flags sort then at" do
      findings =
        run_smell_task("""
        defmodule SortAt do
          def f(items), do: items |> Enum.sort() |> Enum.at(0)
        end
        """)

      assert Enum.any?(
               findings,
               &(&1.kind == :eager_pattern and &1.message =~ "full sort for one element")
             )
    end

    test "flags non-negative drop then take" do
      findings =
        run_smell_task("""
        defmodule DropTake do
          def f(items), do: items |> Enum.drop(5) |> Enum.take(10)
        end
        """)

      assert Enum.any?(findings, &(&1.kind == :eager_pattern and &1.message =~ "Enum.slice/3"))
    end

    test "flags negative drop then take" do
      findings =
        run_smell_task("""
        defmodule DropTakeTail do
          def f(items), do: items |> Enum.drop(-1) |> Enum.take(2)
        end
        """)

      assert Enum.any?(findings, &(&1.kind == :eager_pattern and &1.message =~ "Enum.slice/3"))
    end

    test "flags take_while then length" do
      findings =
        run_smell_task("""
        defmodule TakeWhileLength do
          def f(items), do: items |> Enum.take_while(& &1.ok?) |> length()
        end
        """)

      assert Enum.any?(
               findings,
               &(&1.kind == :eager_pattern and &1.message =~ "intermediate list")
             )
    end

    test "flags reverse append" do
      findings =
        run_smell_task("""
        defmodule ReverseAppend do
          def f(acc, tail), do: Enum.reverse(acc) ++ tail
        end
        """)

      assert Enum.any?(
               findings,
               &(&1.kind == :suboptimal and &1.message =~ "Enum.reverse(list, tail)")
             )
    end

    test "flags map then join as map_join candidate" do
      findings =
        run_smell_task("""
        defmodule MapJoin do
          def f(items), do: items |> Enum.map(& &1.name) |> Enum.join(",")
        end
        """)

      assert Enum.any?(findings, &(&1.kind == :eager_pattern and &1.message =~ "Enum.map_join/3"))
    end
  end

  describe "dual atom/string key access detection" do
    test "does not flag different map variables" do
      findings =
        run_smell_task("""
        defmodule SeparateContracts do
          def fetch(params, metadata) do
            params["id"] || metadata[:id]
          end
        end
        """)

      assert Enum.filter(findings, &(&1.kind == :dual_key_access)) == []
    end
  end

  describe "idiom mismatch detection" do
    test "flags inspect for module membership" do
      findings =
        run_smell_task("""
        defmodule IdiomA do
          def check(mod) do
            mod |> inspect() |> String.starts_with?("Mix.Tasks.")
          end
        end
        """)

      assert Enum.any?(findings, &(&1.message =~ "inspect/1 for module"))
    end

    test "flags Enum.reverse |> hd" do
      findings =
        run_smell_task("""
        defmodule IdiomC do
          def last_item(list) do
            list |> Enum.reverse() |> hd()
          end
        end
        """)

      assert Enum.any?(findings, &(&1.message =~ "Enum.reverse"))
    end
  end

  describe "clone consistency detection" do
    test "flags return contract drift in similar functions" do
      findings =
        run_smell_task(
          """
          defmodule DriftA do
            def fetch(value) do
              normalized = normalize(value)
              {:ok, normalized}
            end

            defp normalize(value), do: value
          end

          defmodule DriftB do
            def fetch(value) do
              normalized = normalize(value)
              normalized
            end

            defp normalize(value), do: value
          end
          """,
          clone_analysis: [min_mass: 5, min_similarity: 0.8]
        )

      assert Enum.any?(findings, &(&1.kind == :return_contract_drift))
    end

    test "flags map contract drift across similar functions" do
      findings =
        run_smell_task(
          """
          defmodule ContractA do
            def extract(params) do
              id = Map.get(params, "id")
              {:ok, id}
            end
          end

          defmodule ContractB do
            def extract(params) do
              id = Map.get(params, :id)
              {:ok, id}
            end
          end
          """,
          clone_analysis: [min_mass: 5, min_similarity: 0.8]
        )

      assert Enum.any?(findings, &(&1.kind == :map_contract_drift))
    end

    test "flags side-effect order drift across similar functions" do
      findings =
        run_smell_task(
          """
          defmodule EffectA do
            def persist(path, value) do
              File.write!(path, value)
              send(self(), value)
              :ok
            end
          end

          defmodule EffectB do
            def persist(path, value) do
              send(self(), value)
              File.write!(path, value)
              :ok
            end
          end
          """,
          clone_analysis: [min_mass: 5, min_similarity: 0.6]
        )

      assert Enum.any?(findings, &(&1.kind == :side_effect_order_drift))
    end

    test "flags validation drift before write effects" do
      findings =
        run_smell_task(
          """
          defmodule ValidationA do
            def create(path, body) do
              body = validate_required(body)
              File.write!(path, body)
              {:ok, body}
            end
          end

          defmodule ValidationB do
            def create(path, body) do
              body = normalize(body)
              File.write!(path, body)
              {:ok, body}
            end
          end
          """,
          clone_analysis: [min_mass: 5, min_similarity: 0.8]
        )

      assert Enum.any?(findings, &(&1.kind == :validation_drift))
    end
  end

  describe "behaviour candidate detection" do
    test "flags modules exposing the same public callbacks" do
      findings =
        run_smell_task("""
        defmodule Providers.HTTP do
          def init(opts), do: opts
          def fetch(id), do: {:ok, id}
          def normalize(value), do: value
        end

        defmodule Providers.File do
          def init(opts), do: opts
          def fetch(id), do: {:ok, id}
          def normalize(value), do: value
        end

        defmodule Providers.Mock do
          def init(opts), do: opts
          def fetch(id), do: {:ok, id}
          def normalize(value), do: value
        end
        """)

      assert [%{kind: :behaviour_candidate} = finding] =
               Enum.filter(findings, &(&1.kind == :behaviour_candidate))

      assert finding.occurrences == 3
      assert "init/1" in finding.callbacks
      assert "fetch/1" in finding.callbacks
      assert "normalize/1" in finding.callbacks
      assert Enum.any?(finding.modules, &(&1 == "Providers.HTTP"))
      assert finding.message =~ "consider extracting a behaviour"
    end

    test "uses configured thresholds" do
      findings =
        run_smell_task(
          """
          defmodule Providers.HTTP do
            def fetch(id), do: {:ok, id}
            def normalize(value), do: value
          end

          defmodule Providers.File do
            def fetch(id), do: {:ok, id}
            def normalize(value), do: value
          end
          """,
          smells: [behaviour_candidate: [min_modules: 2, min_callbacks: 2]]
        )

      assert [%{kind: :behaviour_candidate}] =
               Enum.filter(findings, &(&1.kind == :behaviour_candidate))
    end

    test "does not flag pairs of similar modules by default" do
      findings =
        run_smell_task("""
        defmodule Providers.HTTP do
          def init(opts), do: opts
          def fetch(id), do: {:ok, id}
          def normalize(value), do: value
        end

        defmodule Providers.File do
          def init(opts), do: opts
          def fetch(id), do: {:ok, id}
          def normalize(value), do: value
        end
        """)

      assert Enum.filter(findings, &(&1.kind == :behaviour_candidate)) == []
    end
  end

  describe "collection idiom detection" do
    test "flags redundant Enum.join empty separator" do
      findings =
        run_smell_task("""
        defmodule CollectionIdioms do
          def join(parts), do: Enum.join(parts, "")
        end
        """)

      assert [%{kind: :suboptimal} = finding] =
               Enum.filter(findings, &String.contains?(&1.message, "empty separator"))

      assert finding.message =~ "Enum.join"
    end

    test "flags String.graphemes counted through length or Enum.count" do
      findings =
        run_smell_task("""
        defmodule CollectionIdioms do
          def len(value), do: length(String.graphemes(value))
          def count(value), do: value |> String.graphemes() |> Enum.count()
        end
        """)

      matching = Enum.filter(findings, &String.contains?(&1.message, "String.length/1"))
      assert length(matching) == 2
    end

    test "flags String.length one-character checks" do
      findings =
        run_smell_task("""
        defmodule CollectionIdioms do
          def one?(value), do: String.length(value) == 1
          def not_one?(value), do: 1 != String.length(value)
        end
        """)

      matching = Enum.filter(findings, &String.contains?(&1.message, "one character"))
      assert length(matching) == 2
    end

    test "does not flag Enum.take with negative count (no better alternative)" do
      findings =
        run_smell_task("""
        defmodule CollectionIdioms do
          def last_three(values), do: Enum.take(values, -3)
          def last_two(values), do: values |> Enum.take(-2)
        end
        """)

      assert Enum.filter(findings, &String.contains?(&1.message, "Enum.take")) == []
    end

    test "flags Integer.to_string to String.to_charlist digit extraction" do
      findings =
        run_smell_task("""
        defmodule CollectionIdioms do
          def digits(value), do: value |> Integer.to_string(2) |> String.to_charlist()
        end
        """)

      assert [%{kind: :suboptimal} = finding] =
               Enum.filter(findings, &String.contains?(&1.message, "Integer.to_string"))

      assert finding.message =~ "Integer.digits/2"
    end
  end

  describe "compile-time vs runtime config detection" do
    test "flags Application runtime env captured in module attributes" do
      findings =
        run_smell_task("""
        defmodule ConfigPhase do
          @endpoint Application.get_env(:my_app, :endpoint)
          def endpoint, do: @endpoint
        end
        """)

      assert [%{kind: :config_phase} = finding] =
               Enum.filter(findings, &(&1.kind == :config_phase))

      assert finding.message =~ "module attribute calls Application.get_env at compile time"
      assert finding.message =~ "compile_env"
      assert finding.message =~ "compile time"
    end

    test "flags compile_env used inside runtime functions" do
      findings =
        run_smell_task("""
        defmodule ConfigPhase do
          def endpoint do
            Application.compile_env(:my_app, :endpoint)
          end
        end
        """)

      assert [%{kind: :config_phase} = finding] =
               Enum.filter(findings, &(&1.kind == :config_phase))

      assert finding.message =~ "Application.compile_env inside a function"
      assert finding.message =~ "compile-time"
    end

    test "does not flag explicit compile-time module attributes or runtime function reads" do
      findings =
        run_smell_task("""
        defmodule ConfigPhase do
          @endpoint Application.compile_env(:my_app, :endpoint)
          def endpoint, do: Application.get_env(:my_app, :endpoint)
        end
        """)

      assert Enum.filter(findings, &(&1.kind == :config_phase)) == []
    end
  end

  describe "fixed-shape map detection" do
    test "flags repeated atom-key map shapes" do
      findings =
        run_smell_task("""
        defmodule RepeatedShapes do
          def a, do: %{id: 1, kind: :a, target: "a"}
          def b, do: %{id: 2, kind: :b, target: "b"}
          def c, do: %{id: 3, kind: :c, target: "c"}
        end
        """)

      assert [%{kind: :fixed_shape_map} = finding] =
               Enum.filter(findings, &(&1.kind == :fixed_shape_map))

      assert finding.keys == ["id", "kind", "target"]
      assert finding.occurrences == 3
      assert finding.message =~ "consider a struct or explicit contract"
    end

    test "does not flag isolated map literals" do
      findings =
        run_smell_task("""
        defmodule OneShape do
          def a, do: %{id: 1, kind: :a, target: "a"}
        end
        """)

      assert Enum.filter(findings, &(&1.kind == :fixed_shape_map)) == []
    end

    test "uses configured thresholds and evidence limit" do
      findings =
        run_smell_task(
          """
          defmodule RepeatedSmallShapes do
            def a, do: %{id: 1, kind: :a}
            def b, do: %{id: 2, kind: :b}
          end
          """,
          smells: [fixed_shape_map: [min_keys: 2, min_occurrences: 2, evidence_limit: 1]]
        )

      assert [%{kind: :fixed_shape_map} = finding] =
               Enum.filter(findings, &(&1.kind == :fixed_shape_map))

      assert finding.keys == ["id", "kind"]
      assert finding.occurrences == 2
      assert length(finding.evidence) == 1
    end
  end

  describe "string building (iolist) detection" do
    test "Enum.map with interpolation piped to Enum.join" do
      findings =
        run_smell_task("""
        defmodule MapJoinInterp do
          def render(items) do
            items
            |> Enum.map(fn item -> "<li>\#{item.name}</li>" end)
            |> Enum.join()
          end
        end
        """)

      string = Enum.filter(findings, &(&1.kind == :string_building))
      assert length(string) == 1
      assert hd(string).message =~ "Enum.map"
      assert hd(string).message =~ "Enum.join"
    end

    test "Enum.map_join with string interpolation" do
      findings =
        run_smell_task("""
        defmodule MapJoinDirect do
          def render(rows) do
            Enum.map_join(rows, ",", fn r -> "\#{r.id}:\#{r.name}" end)
          end
        end
        """)

      string = Enum.filter(findings, &(&1.kind == :string_building))
      assert length(string) == 1
      assert hd(string).message =~ "map_join"
    end

    test "string concat around Enum.join" do
      findings =
        run_smell_task("""
        defmodule ConcatJoin do
          def render(items) do
            "<ul>" <> Enum.join(items, ",") <> "</ul>"
          end
        end
        """)

      string = Enum.filter(findings, &(&1.kind == :string_building))
      assert length(string) == 1
      assert hd(string).message =~ "wrap in a list"
    end

    test "Enum.reduce building string with <>" do
      findings =
        run_smell_task("""
        defmodule ReduceConcat do
          def build(rows) do
            Enum.reduce(rows, "", fn row, acc ->
              acc <> row.name <> ","
            end)
          end
        end
        """)

      string = Enum.filter(findings, &(&1.kind == :string_building))
      assert string != []
      assert Enum.any?(string, &(&1.message =~ "O(n²)"))
    end

    test "iolist in Enum.map is NOT flagged" do
      findings =
        run_smell_task("""
        defmodule GoodIolist do
          def render(items) do
            Enum.map(items, fn item -> ["<li>", item.name, "</li>"] end)
          end
        end
        """)

      string = Enum.filter(findings, &(&1.kind == :string_building))
      assert string == []
    end

    test "Enum.join without interpolation in callback is NOT flagged" do
      findings =
        run_smell_task("""
        defmodule PlainJoin do
          def render(items) do
            items |> Enum.map(& &1.name) |> Enum.join(", ")
          end
        end
        """)

      string = Enum.filter(findings, &(&1.kind == :string_building))
      assert string == []
    end

    test "simple string interpolation outside loop is NOT flagged" do
      findings =
        run_smell_task("""
        defmodule SimpleInterp do
          def greet(name), do: "hello \#{name}"
        end
        """)

      string = Enum.filter(findings, &(&1.kind == :string_building))
      assert string == []
    end
  end

  describe "ported smell patterns" do
    test "flags String.graphemes |> Enum.reverse |> Enum.join" do
      findings =
        run_smell_task("""
        defmodule A do
          def rev(s), do: s |> String.graphemes() |> Enum.reverse() |> Enum.join()
        end
        """)

      assert Enum.any?(findings, &(&1.message =~ "String.reverse"))
    end

    test "flags Map.values piped to Enum functions" do
      findings =
        run_smell_task("""
        defmodule A do
          def check(m), do: m |> Map.values() |> Enum.all?(&is_integer/1)
        end
        """)

      assert Enum.any?(findings, &(&1.message =~ "Map.values"))
    end

    test "flags Enum.map |> Enum.max" do
      findings =
        run_smell_task("""
        defmodule A do
          def biggest(items), do: items |> Enum.map(& &1.size) |> Enum.max()
        end
        """)

      assert Enum.any?(findings, &(&1.message =~ "Enum.max_by"))
    end

    test "flags List.foldl" do
      findings =
        run_smell_task("""
        defmodule A do
          def total(items), do: List.foldl(items, 0, &(&1 + &2))
        end
        """)

      assert Enum.any?(findings, &(&1.message =~ "Enum.reduce"))
    end

    test "does not flag Enum.count with predicate" do
      findings =
        run_smell_task("""
        defmodule A do
          def evens(items), do: Enum.count(items, &(rem(&1, 2) == 0))
        end
        """)

      refute Enum.any?(findings, &(&1.message =~ "protocol dispatch"))
    end

    test "flags Map.put with variable key and boolean value" do
      findings =
        run_smell_task("""
        defmodule A do
          def track(seen, item), do: Map.put(seen, item, true)
        end
        """)

      assert Enum.any?(findings, &(&1.message =~ "MapSet"))
    end

    test "does not flag Map.put with atom key and boolean value" do
      findings =
        run_smell_task("""
        defmodule A do
          def activate(struct), do: Map.put(struct, :active, true)
        end
        """)

      refute Enum.any?(findings, &(&1.message =~ "MapSet"))
    end

    test "flags length == 0" do
      findings =
        run_smell_task("""
        defmodule A do
          def empty?(list), do: length(list) == 0
        end
        """)

      assert Enum.any?(findings, &(&1.message =~ "length"))
    end

    test "flags length > 0" do
      findings =
        run_smell_task("""
        defmodule A do
          def nonempty?(list), do: length(list) > 0
        end
        """)

      assert Enum.any?(findings, &(&1.message =~ "length"))
    end

    test "flags Enum.uniq_by with identity" do
      findings =
        run_smell_task("""
        defmodule A do
          def dedup(items), do: Enum.uniq_by(items, fn x -> x end)
        end
        """)

      assert Enum.any?(findings, &(&1.message =~ "Enum.uniq"))
    end

    test "flags length in guard" do
      findings =
        run_smell_task("""
        defmodule A do
          def triplet(list) when length(list) == 3, do: List.to_tuple(list)
        end
        """)

      assert Enum.any?(findings, &(&1.message =~ "pattern matching"))
    end
  end
end
