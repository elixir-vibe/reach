# credo:disable-for-this-file Credo.Check.Refactor.MapJoin
# credo:disable-for-this-file ExSlop.Check.Refactor.ListFold
# credo:disable-for-this-file ExSlop.Check.Refactor.ManualStringReverse
# credo:disable-for-this-file ExSlop.Check.Refactor.MapIntoLiteral
# credo:disable-for-this-file ExSlop.Check.Refactor.SortThenAt
# credo:disable-for-this-file ExSlop.Check.Refactor.UseMapJoin

defmodule Reach.Smell.Checks.MechanicalReplacementEquivalenceTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Reach.Check.Smells
  alias Reach.Smell.Finding

  property "filter length and count with a predicate are equivalent" do
    check all(values <- list_of(integer()), divisor <- integer(1..10)) do
      predicate = &(rem(&1, divisor) == 0)

      assert values |> Enum.filter(predicate) |> length() === Enum.count(values, predicate)
    end
  end

  property "identity flat_map and concat are equivalent for mixed numeric values" do
    number = one_of([integer(), map(integer(), &(&1 / 10))])

    check all(values <- list_of(list_of(number))) do
      assert Enum.flat_map(values, & &1) === Enum.concat(values)
    end
  end

  property "stream filter first and find are equivalent" do
    check all(values <- list_of(integer()), threshold <- integer()) do
      predicate = &(&1 >= threshold)

      assert values |> Stream.filter(predicate) |> Enum.at(0) === Enum.find(values, predicate)
    end
  end

  property "group lengths and frequencies_by are equivalent" do
    check all(values <- list_of(integer()), divisor <- integer(1..10)) do
      key = &rem(&1, divisor)

      grouped =
        values |> Enum.group_by(key) |> Map.new(fn {value, group} -> {value, length(group)} end)

      assert grouped === Enum.frequencies_by(values, key)
    end
  end

  property "Enum.into MapSet mapper and MapSet.new mapper are equivalent" do
    check all(values <- list_of(integer()), offset <- integer()) do
      mapper = &(&1 + offset)

      assert Enum.into(values, MapSet.new(), mapper) === MapSet.new(values, mapper)
    end
  end

  property "joining duplicated strings and String.duplicate are equivalent" do
    check all(value <- string(:alphanumeric), count <- integer(0..20)) do
      assert value |> List.duplicate(count) |> Enum.join() === String.duplicate(value, count)
    end
  end

  property "deduplicating before MapSet construction is redundant" do
    check all(values <- list_of(integer())) do
      assert values |> Enum.uniq() |> MapSet.new() === MapSet.new(values)
    end
  end

  property "materializing an enumerable before Map.new is redundant" do
    check all(pairs <- list_of(tuple({integer(), integer()}))) do
      assert pairs |> Enum.to_list() |> Map.new() === Map.new(pairs)
    end
  end

  property "reverse append and reverse/2 are equivalent" do
    check all(values <- list_of(integer()), tail <- list_of(integer())) do
      assert Enum.reverse(values) ++ tail === Enum.reverse(values, tail)
    end
  end

  property "map projection membership and cardinality replacements are equivalent" do
    key = one_of([integer(), map(integer(), &(&1 / 10)), string(:alphanumeric)])

    check all(pairs <- list_of(tuple({key, integer()})), candidate <- key) do
      map = Map.new(pairs)

      assert map |> Map.keys() |> Enum.member?(candidate) === Map.has_key?(map, candidate)
      assert map |> Map.keys() |> length() === map_size(map)
      assert map |> Map.values() |> Enum.count() === map_size(map)
    end
  end

  property "non-strict min and max branches preserve mixed numeric ties" do
    number = one_of([integer(), map(integer(), &(&1 / 10))])

    check all(left <- number, right <- number) do
      assert if(left >= right, do: left, else: right) === Kernel.max(left, right)
      assert if(left <= right, do: left, else: right) === Kernel.min(left, right)
    end
  end

  property "map and MapSet constructors preserve values for streamed enumerables" do
    check all(values <- list_of(integer()), offset <- integer()) do
      map_source = Stream.map(values, & &1)
      set_source = Stream.map(values, & &1)
      mapper = &{&1, &1 + offset}

      assert map_source |> Enum.map(mapper) |> Enum.into(%{}) === Map.new(map_source, mapper)
      assert Enum.into(set_source, MapSet.new()) === MapSet.new(set_source)
    end
  end

  property "identity by-operations preserve strict mixed numeric results" do
    number = one_of([integer(), map(integer(), &(&1 / 10))])

    check all(values <- nonempty(list_of(number))) do
      assert Enum.uniq_by(values, & &1) === Enum.uniq(values)
      assert Enum.sort_by(values, & &1) === Enum.sort(values)
      assert Enum.min_by(values, & &1) === Enum.min(values)
      assert Enum.max_by(values, & &1) === Enum.max(values)
      assert Enum.dedup_by(values, & &1) === Enum.dedup(values)
    end
  end

  property "List.foldl and Enum.reduce preserve result and callback order" do
    check all(values <- list_of(integer()), initial <- integer()) do
      callback = fn value, acc -> {value, acc} end

      assert List.foldl(values, initial, callback) === Enum.reduce(values, initial, callback)
    end
  end

  test "grapheme reverse replacement handles composed Unicode" do
    for value <- ["", "é", "👩‍💻 café", "🇫🇮a"] do
      assert value |> String.graphemes() |> Enum.reverse() |> Enum.join() ===
               String.reverse(value)
    end
  end

  test "mixed numeric ties discriminate sort-last from Enum.max" do
    sorted_last = Enum.sort([1, 1.0]) |> Enum.at(-1)
    max_value = Enum.max([1, 1.0])

    assert sorted_last === 1.0
    assert max_value === 1
    refute sorted_last === max_value
  end

  test "removed mechanical recommendations have observable counterexamples" do
    assert [false, true] |> Enum.map(& &1) |> List.first() === false
    assert Enum.find_value([false, true], & &1) === true

    assert [1, 2] |> Enum.map(&(-&1)) |> Enum.max() === -1
    assert Enum.max_by([1, 2], &(-&1)) === 1

    assert 12 |> Integer.to_string() |> String.to_charlist() === ~c"12"
    assert Integer.digits(12) === [1, 2]

    assert [1] |> Enum.map(fn _ -> [[1]] end) |> List.flatten() === [1]
    assert Enum.flat_map([1], fn _ -> [[1]] end) === [[1]]

    assert_raise ArgumentError, fn -> [1] |> List.to_tuple() |> elem(2) end
    assert Enum.at([1], 2) === nil
  end

  test "pipeline fusion can change callback and failure order" do
    {:ok, effects} = Agent.start_link(fn -> [] end)

    mapper = fn value ->
      Agent.update(effects, &[value | &1])
      if value == :bad, do: %{}, else: value
    end

    assert_raise Protocol.UndefinedError, fn ->
      [:bad, "later"] |> Enum.map(mapper) |> Enum.join()
    end

    assert Agent.get(effects, &Enum.reverse/1) === [:bad, "later"]
    Agent.update(effects, fn _ -> [] end)

    assert_raise Protocol.UndefinedError, fn ->
      Enum.map_join([:bad, "later"], mapper)
    end

    assert Agent.get(effects, &Enum.reverse/1) === [:bad]
  end

  test "findings distinguish equivalent, conditional, and review-only advice" do
    findings =
      run_smells("""
      defmodule MechanicalSafety do
        def count_active(values), do: values |> Enum.filter(& &1.active?) |> length()
        def sum_scores(values), do: values |> Enum.map(& &1.score) |> Enum.sum()
        def maximum(values), do: values |> Map.values() |> Enum.max()
      end
      """)

    count = Enum.find(findings, &String.contains?(&1.message, "Enum.count/2"))
    sum = Enum.find(findings, &String.contains?(&1.message, "Enum.map → Enum.sum"))
    maximum = Enum.find(findings, &String.contains?(&1.message, "Enum.max/1 allocates"))

    assert count.remediation_safety == :equivalent
    assert sum.remediation_safety == :conditional
    assert maximum.remediation_safety == :review_only

    count_json = count |> JSON.encode!() |> JSON.decode!()
    sum_json = sum |> JSON.encode!() |> JSON.decode!()

    assert count_json["remediation_safety"] == "equivalent"
    assert sum_json["remediation_safety"] == "conditional"
  end

  test "finding rejects unknown remediation safety values" do
    assert_raise ArgumentError, ~r/remediation_safety/, fn ->
      Finding.new(
        kind: :suboptimal,
        message: "review this",
        location: "sample.ex:1",
        remediation_safety: :automatic
      )
    end
  end

  defp run_smells(source) do
    path =
      Path.join(
        System.tmp_dir!(),
        "reach-mechanical-safety-#{System.unique_integer([:positive])}.ex"
      )

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)

    path
    |> then(&Reach.Project.from_sources([&1], plugins: []))
    |> Smells.run([])
  end
end
