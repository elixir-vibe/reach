defmodule Reach.Evidence.PatternRunnerTest do
  use ExUnit.Case, async: true

  import ExAST.Sigil

  alias Reach.Evidence.PatternRunner
  alias Reach.Evidence.StandardLibraryBypass.Evidence

  test "turns pattern matches into evidence structs" do
    ast = Code.string_to_quoted!("Enum.map(items, &expand/1) |> List.flatten()")

    assert [%Evidence{kind: :manual_flat_map, meta: meta}] =
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
               evidence_module: Evidence
             )

    assert meta[:line] == 1
  end

  test "builder can skip matches" do
    ast = Code.string_to_quoted!("Enum.map(items, &expand/1) |> List.flatten()")

    assert [] =
             PatternRunner.run(
               ast,
               [flat_map: {~p[Enum.map(_, _) |> List.flatten()], fn _match -> nil end}],
               evidence_module: Evidence
             )
  end

  test "builder-provided metadata overrides match metadata" do
    ast = Code.string_to_quoted!("Enum.map(items, &expand/1) |> List.flatten()")

    assert [%Evidence{meta: [line: 42]}] =
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
               evidence_module: Evidence
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
             PatternRunner.run(ast, specs, evidence_module: Evidence)
  end
end
