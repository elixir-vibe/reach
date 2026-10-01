defmodule Reach.Smell.ExecutionClassifierTest do
  use ExUnit.Case, async: true

  alias Reach.Smell.Checks.{DualKeyAccess, RedundantComputation}

  defp check(code, detector) do
    path =
      Path.join(System.tmp_dir!(), "reach_execution_#{:erlang.unique_integer([:positive])}.ex")

    File.write!(path, code)
    on_exit(fn -> File.rm!(path) end)
    project = Reach.Project.from_sources([path])
    Reach.Effects.infer_local_effects(project.nodes)
    detector.run(project)
  end

  test "success, rescue and catch arms do not merge repeated pure calls" do
    assert [] ==
             check(
               """
               defmodule ExceptionAlternatives do
                 def count(items) do
                   try do
                     length(items)
                   rescue
                     ArgumentError -> length(items)
                     RuntimeError -> length(items)
                   catch
                     :throw, :halt -> length(items)
                     :exit, :halt -> length(items)
                   end
                 end
               end
               """,
               RedundantComputation
             )
  end

  test "duplicates within rescue and catch arms remain findings" do
    findings =
      check(
        """
        defmodule ExceptionDuplicates do
          def count(items) do
            try do
              raise "failure"
            rescue
              RuntimeError ->
                first = length(items)
                second = length(items)
                {first, second}
            catch
              :throw, :halt ->
                first = length(items)
                second = length(items)
                {first, second}
            end
          end
        end
        """,
        RedundantComputation
      )

    assert length(findings) == 2
    assert Enum.all?(findings, &(&1.kind == :redundant_computation))
  end

  test "try else and after coexist with the successful body" do
    assert [_finding] =
             check(
               """
               defmodule TrySuccessElse do
                 def count(items) do
                   try do
                     length(items)
                   else
                     count -> {count, length(items)}
                   end
                 end
               end
               """,
               RedundantComputation
             )

    assert [_finding] =
             check(
               """
               defmodule TrySuccessAfter do
                 def count(items) do
                   try do
                     length(items)
                   after
                     length(items)
                   end
                 end
               end
               """,
               RedundantComputation
             )
  end

  test "successive with qualifiers are not mutually exclusive branches" do
    assert [_finding] =
             check(
               """
               defmodule WithSequentialCalls do
                 def count(items) do
                   with first when first > 0 <- length(items),
                        second when second > 0 <- length(items) do
                     {first, second}
                   end
                 end
               end
               """,
               RedundantComputation
             )
  end

  test "nested callback alternatives remain separate but same arm duplicates are detected" do
    assert [] ==
             check(
               """
               defmodule CallbackAlternatives do
                 def render(rows, items) do
                   Enum.map(rows, fn
                     :first -> length(items)
                     :second -> length(items)
                   end)
                 end
               end
               """,
               RedundantComputation
             )

    assert [_finding] =
             check(
               """
               defmodule CallbackDuplicates do
                 def render(rows, items) do
                   Enum.map(rows, fn row ->
                     case row do
                       :first ->
                         first = length(items)
                         second = length(items)
                         {first, second}
                       :second -> length(items)
                     end
                   end)
                 end
               end
               """,
               RedundantComputation
             )
  end

  test "a call before a branch and repeated on that path remains redundant" do
    assert [_finding] =
             check(
               """
               defmodule SequentialBranchDuplicate do
                 def count(items, flag) do
                   first = length(items)
                   if flag do
                     {first, length(items)}
                   else
                     first
                   end
                 end
               end
               """,
               RedundantComputation
             )
  end

  test "rebinding is not the same argument but subsequent same binding is" do
    assert [_finding] =
             check(
               """
               defmodule ReboundArguments do
                 def count(items) do
                   first = length(items)
                   items = []
                   second = length(items)
                   third = length(items)
                   {first, second, third}
                 end
               end
               """,
               RedundantComputation
             )
  end

  test "filter expression fragments are syntax while runtime fragment calls remain checked" do
    assert [] ==
             check(
               """
               defmodule FilterExpressionSyntax do
                 def fragment(_sql, metadata), do: metadata
                 def query(query) do
                   query
                   |> Ash.Query.filter(
                     fragment("(?->>'execution_stage')", metadata) == :validation_failed or
                       fragment("(?->>'execution_stage')", metadata) == :execution_failed
                   )
                 end
               end
               """,
               RedundantComputation
             )

    assert [_finding] =
             check(
               """
               defmodule RuntimeFragmentComputation do
                 def fragment(_sql, metadata), do: metadata
                 def query(metadata) do
                   first = fragment("(?->>'execution_stage')", metadata)
                   second = fragment("(?->>'execution_stage')", metadata)
                   {first, second}
                 end
               end
               """,
               RedundantComputation
             )
  end

  test "pinned runtime computation inside the filter DSL remains checked" do
    assert [_finding] =
             check(
               """
               defmodule FilterPinnedRuntime do
                 def query(query, items) do
                   Ash.Query.filter(query,
                     count == ^length(items) or
                       other_count == ^length(items)
                   )
                 end
               end
               """,
               RedundantComputation
             )
  end

  test "keyword filter arguments are runtime rather than expression syntax" do
    assert [_finding] =
             check(
               """
               defmodule FilterRuntimeKeyword do
                 def query(query, items) do
                   Ash.Query.filter(query, [
                     count: length(items),
                     other_count: length(items)
                   ])
                 end
               end
               """,
               RedundantComputation
             )
  end

  test "strict atom and string schemas in different function clauses do not mix bindings" do
    assert [] ==
             check(
               """
               defmodule AlternativeInputSchemas do
                 def normalize(%{kind: :mock} = params), do: Map.get(params, :symbol)
                 def normalize(%{"kind" => "remote"} = params), do: Map.get(params, "symbol")
               end
               """,
               DualKeyAccess
             )
  end

  test "independent consumers of both key styles still report" do
    assert [%{kind: :dual_key_access}] =
             check(
               """
               defmodule IndependentKeyConsumers do
                 def normalize(params) do
                   atom = Map.get(params, :symbol)
                   string = Map.get(params, "symbol")
                   {atom, string}
                 end
               end
               """,
               DualKeyAccess
             )
  end

  test "rebinding and callback shadowing do not merge distinct maps" do
    assert [] ==
             check(
               """
               defmodule DifferentMapBindings do
                 def normalize(params, rows) do
                   atom = Map.get(params, :symbol)
                   strings = Enum.map(rows, fn params -> Map.get(params, "symbol") end)
                   params = %{}
                   {atom, strings, Map.get(params, "symbol")}
                 end
               end
               """,
               DualKeyAccess
             )
  end

  test "independent captured-map consumers still mix key styles" do
    assert [%{kind: :dual_key_access}] =
             check(
               """
               defmodule CapturedMapConsumers do
                 def normalize(params, rows) do
                   atom = Map.get(params, :symbol)
                   strings = Enum.map(rows, fn _row -> Map.get(params, "symbol") end)
                   {atom, strings}
                 end
               end
               """,
               DualKeyAccess
             )
  end

  test "nil coalescing the same map's key styles remains a loose contract finding" do
    assert [%{kind: :dual_key_access}] =
             check(
               """
               defmodule CoalescedMapContract do
                 def analyzer(metadata), do: metadata["analyzer"] || metadata[:analyzer]
               end
               """,
               DualKeyAccess
             )
  end

  test "a nested Map.get default still reads both styles of the same binding" do
    assert [%{kind: :dual_key_access}] =
             check(
               """
               defmodule DefaultedMapContract do
                 def tab(params), do: Map.get(params, "tab", Map.get(params, :tab, "overview"))
               end
               """,
               DualKeyAccess
             )
  end

  test "a nil-case fallback still reads both styles of the same binding" do
    assert [%{kind: :dual_key_access}] =
             check(
               """
               defmodule NilCaseMapContract do
                 def answer(projection) do
                   case Map.get(projection, :answer) do
                     nil -> Map.get(projection, "answer")
                     answer -> answer
                   end
                 end
               end
               """,
               DualKeyAccess
             )
  end

  test "an arbitrary boolean expression does not exempt mixed-key consumers" do
    assert [%{kind: :dual_key_access}] =
             check(
               """
               defmodule BooleanKeyConsumers do
                 def answer(projection, flag) do
                   atom = projection[:answer] || flag
                   string = projection["answer"]
                   {atom, string}
                 end
               end
               """,
               DualKeyAccess
             )
  end
end
