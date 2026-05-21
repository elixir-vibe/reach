defmodule Reach.Evidence.PatternRunnerTest do
  use ExUnit.Case, async: true

  import ExAST.Sigil

  alias Reach.Evidence.Fact
  alias Reach.Evidence.PatternRunner

  defmodule CustomEvidence do
    @moduledoc false
    defstruct [:kind, :message, :replacement, :meta, :confidence]
  end

  test "turns pattern matches into evidence structs" do
    ast = Code.string_to_quoted!("Enum.map(items, &expand/1) |> List.flatten()")

    assert [%Fact{family: :stdlib, kind: :manual_flat_map, meta: meta}] =
             PatternRunner.run(
               ast,
               [
                 flat_map:
                   {~p[Enum.map(_, _) |> List.flatten()],
                    fn _match ->
                      %{
                        kind: :manual_flat_map,
                        message: "use flat_map",
                        replacement: "Enum.flat_map/2",
                        confidence: :high
                      }
                    end}
               ],
               family: :stdlib
             )

    assert meta[:line] == 1
  end

  test "builder can skip matches" do
    ast = Code.string_to_quoted!("Enum.map(items, &expand/1) |> List.flatten()")

    assert [] =
             PatternRunner.run(
               ast,
               [flat_map: {~p[Enum.map(_, _) |> List.flatten()], fn _match -> nil end}],
               family: :stdlib
             )

    assert [] =
             PatternRunner.run(
               ast,
               [flat_map: {~p[Enum.map(_, _) |> List.flatten()], fn _match -> false end}],
               family: :stdlib
             )
  end

  test "builder-provided metadata overrides match metadata" do
    ast = Code.string_to_quoted!("Enum.map(items, &expand/1) |> List.flatten()")

    assert [%Fact{meta: [line: 42]}] =
             PatternRunner.run(
               ast,
               [
                 flat_map:
                   {~p[Enum.map(_, _) |> List.flatten()],
                    fn _match ->
                      %{
                        kind: :manual_flat_map,
                        message: "use flat_map",
                        replacement: "Enum.flat_map/2",
                        confidence: :high,
                        meta: [line: 42]
                      }
                    end}
               ],
               family: :stdlib
             )
  end

  test "skips ExAST alias collection failures for dynamic import options" do
    ast =
      Code.string_to_quoted!("""
      defmodule DynamicImport do
        import Some.Module, unquote(opts)
      end
      """)

    assert [] =
             PatternRunner.run(
               ast,
               [
                 query:
                   {~p[String.split(_, "&")], fn _match -> %{kind: :manual_query_parsing} end}
               ],
               family: :stdlib
             )
  end

  test "supports custom evidence structs without family fields" do
    ast = Code.string_to_quoted!("Enum.map(items, &expand/1) |> List.flatten()")

    assert [%CustomEvidence{kind: :manual_flat_map}] =
             PatternRunner.run(
               ast,
               [
                 flat_map:
                   {~p[Enum.map(_, _) |> List.flatten()],
                    fn _match ->
                      %{
                        kind: :manual_flat_map,
                        message: "use flat_map",
                        replacement: "Enum.flat_map/2",
                        confidence: :high
                      }
                    end}
               ],
               evidence_module: CustomEvidence,
               family: :stdlib
             )
  end

  test "runs multiple patterns in one pass" do
    ast =
      Code.string_to_quoted!("""
      Enum.map(items, &expand/1) |> List.flatten()
      String.split(query, "&")
      """)

    specs = [
      flat_map:
        {~p[Enum.map(_, _) |> List.flatten()],
         fn _match ->
           %{
             kind: :manual_flat_map,
             message: "use flat_map",
             replacement: "Enum.flat_map/2",
             confidence: :high
           }
         end},
      query:
        {~p[String.split(_, "&")],
         fn _match ->
           %{
             kind: :manual_query_parsing,
             message: "use URI.decode_query",
             replacement: "URI.decode_query/1",
             confidence: :high
           }
         end}
    ]

    assert [%{kind: :manual_flat_map}, %{kind: :manual_query_parsing}] =
             PatternRunner.run(ast, specs, family: :stdlib)
  end
end
