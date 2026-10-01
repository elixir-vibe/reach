defmodule Reach.Smell.CostSemanticsTest do
  use ExUnit.Case, async: true

  alias Reach.Smell.Checks.{CollectionIdioms, IdiomMismatch, LoopAntipattern, StringBuilding}

  defp findings(check, definitions) do
    path = Path.join(System.tmp_dir!(), "reach_cost_#{System.unique_integer([:positive])}.ex")
    File.write!(path, "defmodule CostExample do\n#{definitions}\nend\n")
    on_exit(fn -> File.rm!(path) end)
    path |> List.wrap() |> Reach.Project.from_sources() |> check.run()
  end

  defp messages(check, definitions, prefix) do
    findings(check, definitions)
    |> Enum.filter(&String.starts_with?(&1.message, prefix))
  end

  test "append copies only the growing left accumulator, not newly computed issues" do
    assert [_] =
             messages(
               LoopAntipattern,
               """
               def append(items), do: Enum.reduce(items, [], fn item, acc -> acc ++ [item] end)
               """,
               "++ inside reduce"
             )

    assert [] =
             messages(
               LoopAntipattern,
               """
               def prepend(items), do: Enum.reduce(items, [], fn item, acc -> new_issues(item) ++ acc end)
               """,
               "++ inside reduce"
             )
  end

  test "captured and assigned accumulator appends remain detected" do
    assert [_] =
             messages(
               LoopAntipattern,
               """
               def append(items), do: Enum.reduce(items, [], &(&2 ++ [&1]))
               """,
               "++ inside reduce"
             )

    assert [_] =
             messages(
               LoopAntipattern,
               """
               def append(items) do
                 Enum.reduce(items, [], fn item, acc ->
                   next = acc ++ [item]
                   next
                 end)
               end
               """,
               "++ inside reduce"
             )
  end

  test "fixed enumeration is linear in result size, unlike a variable-length enumeration" do
    assert [] =
             messages(
               LoopAntipattern,
               """
               def collect(first, second) do
                 Enum.reduce([first, second], [], fn addresses, collected -> collected ++ addresses end)
               end
               """,
               "++ inside reduce"
             )

    assert [_] =
             messages(
               LoopAntipattern,
               """
               def collect(groups), do: Enum.reduce(groups, [], fn addresses, collected -> collected ++ addresses end)
               """,
               "++ inside reduce"
             )

    assert [_] =
             messages(
               LoopAntipattern,
               """
               def collect(first, rest) do
                 Enum.reduce([first | rest], [], fn addresses, collected -> collected ++ addresses end)
               end
               """,
               "++ inside reduce"
             )
  end

  test "binary prefix patterns and exception messages do not build the accumulator" do
    for check <- [LoopAntipattern, StringBuilding] do
      assert [] =
               messages(
                 check,
                 """
                 def scrub(items) do
                   Enum.map_reduce(items, "", fn item, acc ->
                     case item do
                       "prefix_" <> _token -> {nil, acc}
                       _ -> {item, acc}
                     end
                   end)
                 end
                 def validate(items) do
                   Enum.reduce(items, "", fn item, acc ->
                     if duplicate?(item), do: raise("duplicate " <> inspect(item)), else: acc
                   end)
                 end
                 """,
                 if(check == LoopAntipattern,
                   do: "<> inside reduce",
                   else: "Enum.reduce building string"
                 )
               )

      assert [_] =
               messages(
                 check,
                 """
                 def build(items), do: Enum.reduce(items, "", fn item, acc -> acc <> item end)
                 """,
                 if(check == LoopAntipattern,
                   do: "<> inside reduce",
                   else: "Enum.reduce building string"
                 )
               )
    end
  end

  test "interpolated accumulator output remains detected, but bounded diagnostics do not" do
    assert [_] =
             messages(
               StringBuilding,
               ~S"""
               def build(items), do: Enum.reduce(items, "", fn item, acc -> "#{acc}#{item}" end)
               """,
               "Enum.reduce building string"
             )

    assert [] =
             messages(
               StringBuilding,
               ~S"""
               def validate(items) do
                 Enum.reduce(items, "", fn item, acc ->
                   if duplicate?(item), do: raise("duplicate #{item}"), else: acc
                 end)
               end
               """,
               "Enum.reduce building string"
             )

    assert [] =
             messages(
               StringBuilding,
               ~S"""
               def measure(items), do: Enum.reduce(items, "", fn item, acc -> "#{byte_size(acc)}#{item}" end)
               """,
               "Enum.reduce building string"
             )
  end

  test "a concatenated parser input is not returned output accumulation" do
    assert [] =
             messages(
               LoopAntipattern,
               """
               def parse(chunks) do
                 Enum.reduce(chunks, {%{}, "", false}, fn chunk, {buckets, pending, header?} ->
                   parse_chunk!(pending <> decompress(chunk), buckets, header?)
                 end)
               end
               """,
               "<> inside reduce"
             )

    assert [_] =
             messages(
               LoopAntipattern,
               """
               def build(chunks) do
                 Enum.reduce(chunks, {%{}, ""}, fn chunk, {buckets, output} ->
                   {buckets, output <> chunk}
                 end)
               end
               """,
               "<> inside reduce"
             )
  end

  test "map_reduce output is distinct from its accumulator feedback" do
    assert [] =
             messages(
               LoopAntipattern,
               """
               def render(items), do: Enum.map_reduce(items, "", fn item, acc -> {acc <> item, acc} end)
               """,
               "<> inside reduce"
             )

    assert [_] =
             messages(
               LoopAntipattern,
               """
               def build(items), do: Enum.map_reduce(items, "", fn item, acc -> {item, acc <> item} end)
               """,
               "<> inside reduce"
             )
  end

  test "reduce_while halt is not feedback, but a continuing accumulator is" do
    assert [] =
             messages(
               LoopAntipattern,
               """
               def stop(items), do: Enum.reduce_while(items, [], fn item, acc -> {:halt, acc ++ [item]} end)
               """,
               "++ inside reduce"
             )

    assert [_] =
             messages(
               LoopAntipattern,
               """
               def build(items) do
                 Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} when is_list(item) ->
                   {:cont, {:ok, acc ++ item}}
                 end)
               end
               """,
               "++ inside reduce"
             )
  end

  test "recursive list tails are not copied prefixes" do
    assert [] =
             messages(
               LoopAntipattern,
               """
               def build([]), do: []
               def build([item | rest]), do: [item] ++ build(rest)
               """,
               "++ inside reduce"
             )

    assert [_] =
             messages(
               LoopAntipattern,
               """
               def build([]), do: []
               def build([item | rest]), do: build(rest) ++ [item]
               """,
               "++ inside reduce"
             )
  end

  test "Enum.at after maps is not a callback or an unrelated recursive clause" do
    assert [] =
             messages(
               LoopAntipattern,
               """
               def select(:again, results), do: select(:ready, results)
               def select(:ready, results) do
                 all_results = Enum.map(results, &transform/1)
                 Enum.at(all_results, 0)
               end
               """,
               "Enum.at/2 inside loop"
             )

    assert [] =
             messages(
               LoopAntipattern,
               """
               def select(:ready, results) do
                 selected = Enum.at(results, 0)
                 select(:done, selected)
               end
               def select(:done, selected), do: selected
               """,
               "Enum.at/2 inside loop"
             )

    assert [_] =
             messages(
               LoopAntipattern,
               """
               def select(:ready, results) do
                 Enum.at(results, 0)
                 select(:again, results)
               end
               def select(:again, results), do: select(:ready, results)
               """,
               "Enum.at/2 inside loop"
             )

    assert [_] =
             messages(
               LoopAntipattern,
               """
               def select(items), do: Enum.map(items, fn item -> Enum.at(item, 0) end)
               """,
               "Enum.at/2 inside loop"
             )

    assert [_] =
             messages(
               LoopAntipattern,
               """
               def select([], _items), do: []
               def select([index | rest], items), do: [Enum.at(items, index) | select(rest, items)]
               """,
               "Enum.at/2 inside loop"
             )
  end

  test "manual frequencies require item keys, initial one and increment by one" do
    assert [_] =
             messages(
               LoopAntipattern,
               """
               def count(items) do
                 Enum.reduce(items, %{}, fn item, acc -> Map.update(acc, item, 1, &(&1 + 1)) end)
               end
               """,
               "manual frequency counting"
             )

    assert [_] =
             messages(
               LoopAntipattern,
               """
               def count(items) do
                 Enum.reduce(items, %{}, fn item, acc -> Map.update(acc, item, 1, fn count -> count + 1 end) end)
               end
               """,
               "manual frequency counting"
             )

    assert [_] =
             messages(
               LoopAntipattern,
               """
               def count(items) do
                 Enum.reduce(items, %{}, &Map.update(&2, &1, 1, fn count -> 1 + count end))
               end
               """,
               "manual frequency counting"
             )

    for update <- [
          "Map.update(acc, identity_key(item), item, &merge_legs(&1, item))",
          "Map.update(acc, item, 0, &(&1 + 1))",
          "Map.update(acc, item, 1, &(&1 + 2))",
          "Map.update(acc, identity_key(item), 1, &(&1 + 1))"
        ] do
      assert [] =
               messages(
                 LoopAntipattern,
                 """
                 def aggregate(items), do: Enum.reduce(items, %{}, fn item, acc -> #{update} end)
                 """,
                 "manual frequency counting"
               )
    end
  end

  test "function-head advice applies only to directly bound conjunctive parameters" do
    assert [_] =
             messages(
               IdiomMismatch,
               """
               def process(reason) when reason == :manual and is_atom(reason), do: :ok
               """,
               "guard compares parameter"
             )

    for definitions <- [
          "def process(reason), do: case reason do value when value == :manual -> :ok; _ -> :other end",
          "def process(reason), do: case :ok do _ when reason == :manual -> :ok; _ -> :other end",
          "def process(event) when event == :alpaca or is_struct(event, Decimal), do: :ok",
          "def process({reason}) when reason == :manual, do: :ok"
        ] do
      assert [] = messages(IdiomMismatch, definitions, "guard compares parameter")
    end
  end

  test "numeric equality retains float acceptance unless exactness is proven" do
    assert [] =
             messages(
               IdiomMismatch,
               "def process(index) when index == 0, do: :ok",
               "guard compares parameter"
             )

    assert [_] =
             messages(
               IdiomMismatch,
               "def process(index) when index === 0, do: :ok",
               "guard compares parameter"
             )

    assert [_] =
             messages(
               IdiomMismatch,
               "def process(index) when is_integer(index) and index == 0, do: :ok",
               "guard compares parameter"
             )

    assert [] =
             messages(
               IdiomMismatch,
               "def process(index) when is_integer(index) or index == 0, do: :ok",
               "guard compares parameter"
             )
  end

  test "length advice requires actual list evidence and preserves polymorphic counts" do
    assert [_] =
             messages(
               CollectionIdioms,
               "def count(), do: Enum.count([:one, :two])",
               "Enum.count/1 without predicate"
             )

    assert [_] =
             messages(
               CollectionIdioms,
               "def count(items), do: items |> Enum.map(&transform/1) |> Enum.count()",
               "Enum.count/1 without predicate"
             )

    assert [_] =
             messages(
               CollectionIdioms,
               "def count(items), do: Enum.count(Map.keys(items))",
               "Enum.count/1 without predicate"
             )

    assert [] =
             messages(
               CollectionIdioms,
               """
               @spec count(list() | MapSet.t()) :: non_neg_integer()
               def count(items), do: Enum.count(items)
               """,
               "Enum.count/1 without predicate"
             )

    assert [] =
             messages(
               CollectionIdioms,
               "def count(items), do: Enum.count(MapSet.new(items))",
               "Enum.count/1 without predicate"
             )

    assert [] =
             messages(
               CollectionIdioms,
               "def count(items), do: Enum.count(items, &valid?/1)",
               "Enum.count/1 without predicate"
             )
  end

  test "map fields and bucket callbacks retain growing list feedback" do
    for definitions <- [
          "def build(xs), do: Enum.reduce(xs, %{items: []}, fn x, acc -> %{acc | items: acc.items ++ [x]} end)",
          "def build(xs), do: Enum.reduce(xs, %{items: []}, fn x, %{items: items} -> %{items: items ++ [x]} end)",
          "def build(xs), do: Enum.reduce(xs, %{}, fn x, acc -> Map.update(acc, k(x), [x], &(&1 ++ [x])) end)",
          "def build(xs), do: Enum.reduce(xs, %{}, fn x, acc -> Map.update(acc, k(x), [x], fn bucket -> bucket ++ [x] end) end)",
          "def build(xs), do: Enum.reduce(xs, %{items: []}, fn x, acc -> Map.put(acc, :items, Map.get(acc, :items) ++ [x]) end)",
          "def build(xs, key), do: Enum.reduce(xs, %{}, fn x, acc -> Map.put(acc, key, acc[key] ++ [x]) end)",
          "def build(xs), do: Enum.reduce(xs, %{nested: %{items: []}}, fn x, acc -> %{acc | nested: %{acc.nested | items: acc.nested.items ++ [x]}} end)"
        ] do
      assert [_] = messages(LoopAntipattern, definitions, "++ inside reduce")
    end

    for definitions <- [
          "def build(xs), do: Enum.reduce(xs, %{items: []}, fn x, acc -> %{acc | items: issues(x) ++ acc.items} end)",
          "def build(xs), do: Enum.reduce(xs, %{items: [], other: []}, fn x, acc -> %{acc | other: acc.items ++ [x]} end)",
          "def build(xs), do: Enum.reduce(xs, %{}, fn x, acc -> Map.update(acc, k(x), [x], &(&1 ++ [x])); acc end)",
          "def build(xs), do: Enum.reduce(xs, %{}, fn x, acc -> Map.update(new_map(x), k(x), [x], &(&1 ++ [x])) end)"
        ] do
      assert [] = messages(LoopAntipattern, definitions, "++ inside reduce")
    end
  end

  test "nested binary fields retain string growth but not parser inputs or diagnostics" do
    for definitions <- [
          "def build(xs), do: Enum.reduce(xs, %{text: \"\"}, fn x, acc -> %{acc | text: acc.text <> x} end)",
          "def build(xs), do: Enum.reduce(xs, %{}, fn x, acc -> Map.update(acc, k(x), x, &(&1 <> x)) end)",
          ~S[def build(xs), do: Enum.reduce(xs, %{text: ""}, fn x, acc -> %{acc | text: "#{acc.text}#{x}"} end)]
        ] do
      assert [_] = messages(StringBuilding, definitions, "Enum.reduce building string")
    end

    for definitions <- [
          "def build(xs), do: Enum.reduce(xs, %{text: \"\"}, fn x, acc -> %{acc | text: parse(acc.text <> x)} end)",
          "def build(xs), do: Enum.reduce(xs, %{text: \"\"}, fn x, acc -> raise(\"duplicate \" <> inspect(x)); acc end)",
          "def build(xs), do: Enum.reduce(xs, %{}, fn x, acc -> Map.update(acc, k(x), x, fn text -> parse(text <> x) end) end)"
        ] do
      assert [] = messages(StringBuilding, definitions, "Enum.reduce building string")
    end
  end
end
