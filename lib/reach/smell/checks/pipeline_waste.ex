defmodule Reach.Smell.Checks.PipelineWaste do
  @moduledoc "Pattern-based detection of redundant pipeline operations."

  use Reach.Smell.Check.Source

  alias Reach.Smell.Helpers

  smell(
    ~p[Enum.filter(_, _) |> Enum.count()],
    :suboptimal,
    "Enum.filter → Enum.count: use Enum.count/2 instead",
    remediation_safety: :equivalent
  )

  smell(
    ~p[Enum.filter(_, _) |> length()],
    :suboptimal,
    "Enum.filter → length: use Enum.count/2 instead",
    remediation_safety: :equivalent
  )

  smell(
    ~p[Stream.filter(_, _) |> Enum.at(0)],
    :suboptimal,
    "Stream.filter/2 |> Enum.at(0) can be replaced with Enum.find/2 for lazy single-pass search",
    remediation_safety: :equivalent
  )

  smell(
    ~p[Enum.take_while(_, _) |> Enum.count()],
    :eager_pattern,
    "Enum.take_while → Enum.count: allocates an intermediate list; use Enum.reduce_while/3"
  )

  smell(
    ~p[Enum.take_while(_, _) |> length()],
    :eager_pattern,
    "Enum.take_while → length: allocates an intermediate list; use Enum.reduce_while/3"
  )

  smell(
    ~p[Enum.map(_, _) |> Enum.join()],
    :eager_pattern,
    "Enum.map → Enum.join allocates an intermediate list; fuse with Enum.map_join/3 only when callbacks are pure and every mapped value converts successfully, because fusion changes callback/conversion failure order",
    remediation_safety: :conditional
  )

  smell(
    ~p[Enum.map(_, _) |> Enum.join(_)],
    :eager_pattern,
    "Enum.map → Enum.join allocates an intermediate list; fuse with Enum.map_join/3 only when callbacks are pure and every mapped value converts successfully, because fusion changes callback/conversion failure order",
    remediation_safety: :conditional
  )

  smell(
    ~p[Enum.join(_, "")],
    :suboptimal,
    ~S[Enum.join/1 defaults to empty separator; remove the "" argument],
    remediation_safety: :equivalent
  )

  smell(
    ~p[Enum.map_join(_, "", _)],
    :suboptimal,
    ~S[Enum.map_join/3 defaults to empty separator; remove the "" argument],
    remediation_safety: :equivalent
  )

  smell(
    ~p[Enum.with_index(_) |> Enum.reduce(_, _)],
    :eager_pattern,
    "Enum.with_index/1 before Enum.reduce/3 builds index pairs eagerly; use Stream.with_index/1 only when the reducer is total and pure so interleaving cannot be observed",
    remediation_safety: :conditional
  )

  smell(
    ~p[_ |> (fn _ -> _ end).()],
    :suboptimal,
    "anonymous fn applied with .() in pipe; use then/2 instead",
    remediation_safety: :equivalent
  )

  smell(
    ~p[Enum.map(_, _) |> Enum.sum()],
    :eager_pattern,
    "Enum.map → Enum.sum allocates an intermediate list; fuse only when the callback is pure and all mapped values are summable so mapping-versus-addition failure order cannot differ",
    remediation_safety: :conditional
  )

  smell(
    ~p[List.foldl(_, _, _)],
    :suboptimal,
    "List.foldl/3 is non-idiomatic; use Enum.reduce/3",
    remediation_safety: :equivalent
  )

  smell(
    ~p[List.foldr(_, _, _)],
    :suboptimal,
    "List.foldr/3 is non-idiomatic; review Enum.reverse/1 plus Enum.reduce/3 while preserving right-to-left callback order"
  )

  # Enum._by with identity function
  smell(
    ~p[Enum.uniq_by(_, fn x -> x end)],
    :suboptimal,
    "Enum.uniq_by with identity function; use Enum.uniq/1",
    remediation_safety: :equivalent
  )

  smell(
    ~p[Enum.sort_by(_, fn x -> x end)],
    :suboptimal,
    "Enum.sort_by with identity function; use Enum.sort/1",
    remediation_safety: :equivalent
  )

  smell(
    ~p[Enum.min_by(_, fn x -> x end)],
    :suboptimal,
    "Enum.min_by with identity function; use Enum.min/1",
    remediation_safety: :equivalent
  )

  smell(
    ~p[Enum.max_by(_, fn x -> x end)],
    :suboptimal,
    "Enum.max_by with identity function; use Enum.max/1",
    remediation_safety: :equivalent
  )

  smell(
    ~p[Enum.dedup_by(_, fn x -> x end)],
    :suboptimal,
    "Enum.dedup_by with identity function; use Enum.dedup/1",
    remediation_safety: :equivalent
  )

  smell(
    from(~p[Enum.flat_map(_, callback)])
    |> where(Helpers.identity_fn?(^callback)),
    :suboptimal,
    "Enum.flat_map/2 with identity function; use Enum.concat/1",
    remediation_safety: :equivalent
  )

  smell(
    ~p[unless _ do _ else _ end],
    :suboptimal,
    "unless/else is non-idiomatic; use if with the positive case first"
  )

  smell(
    ~p[cond do _ -> _; true -> _ end],
    :suboptimal,
    "cond with two clauses where the second is `true` is just if/else"
  )

  smell(
    ~p[@doc false
    defp _(...) do ... end],
    :suboptimal,
    "@doc false on defp is redundant; private functions cannot have documentation"
  )

  smell(
    quote do
      case _ do
        _ -> true
        _ -> false
      end
    end,
    :suboptimal,
    "case returns true/false; review match?/2 only when unmatched inputs should return false rather than preserve CaseClauseError"
  )

  smell(
    quote do
      case _ do
        _ -> false
        _ -> true
      end
    end,
    :suboptimal,
    "case returns false/true; review not match?/2 only when unmatched inputs should return true rather than preserve CaseClauseError"
  )

  @boolean_ops [:==, :!=, :===, :!==, :>, :<, :>=, :<=, :and, :or, :not, :in]

  smell(
    :boolean_case,
    :suboptimal,
    "case on boolean with true/false clauses; use if/else",
    mode: :ast,
    prefilter: {:all, ["case"]}
  )

  defp boolean_case({:case, meta, [subject, clauses_ast]}) do
    with {:ok, clauses} <- case_clauses(clauses_ast),
         true <- boolean_subject?(subject),
         true <- boolean_case_clauses?(clauses) do
      {:ok, meta}
    end
  end

  defp boolean_case(_node), do: nil

  defp case_clauses(do: clauses) when is_list(clauses), do: {:ok, clauses}

  defp case_clauses([{do_block, clauses}])
       when is_list(clauses) and elem(do_block, 0) == :__block__, do: {:ok, clauses}

  defp case_clauses(_clauses_ast), do: :error

  defp boolean_subject?({op, _, _}) when op in @boolean_ops, do: true
  defp boolean_subject?(_subject), do: false

  defp boolean_case_clauses?([
         {:->, _, [[first], _first_body]},
         {:->, _, [[second], _second_body]}
       ]) do
    (boolean_literal?(first) and wildcard?(second)) or
      (boolean_literal?(second) and wildcard?(first)) or
      (boolean_literal?(first) and boolean_literal?(second))
  end

  defp boolean_case_clauses?(_clauses), do: false

  defp boolean_literal?(value), do: unwrap_literal(value) in [true, false]
  defp wildcard?(node), do: match?({:_, _, _}, unwrap_literal(node))
  defp unwrap_literal({:__block__, _meta, [value]}), do: value
  defp unwrap_literal(value), do: value
end
