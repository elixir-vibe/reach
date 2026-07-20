defmodule Reach.Smell.Checks.MechanicalReplacementEquivalenceTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  property "filter length and count with a predicate are equivalent" do
    check all(values <- list_of(integer()), divisor <- integer(1..10)) do
      predicate = &(rem(&1, divisor) == 0)

      assert values |> Enum.filter(predicate) |> length() == Enum.count(values, predicate)
    end
  end

  property "identity flat_map and concat are equivalent" do
    check all(values <- list_of(list_of(integer()))) do
      assert Enum.flat_map(values, & &1) == Enum.concat(values)
    end
  end

  property "stream filter first and find are equivalent" do
    check all(values <- list_of(integer()), threshold <- integer()) do
      predicate = &(&1 >= threshold)

      assert values |> Stream.filter(predicate) |> Enum.at(0) == Enum.find(values, predicate)
    end
  end

  property "group lengths and frequencies_by are equivalent" do
    check all(values <- list_of(integer()), divisor <- integer(1..10)) do
      key = &rem(&1, divisor)

      grouped =
        values |> Enum.group_by(key) |> Map.new(fn {value, group} -> {value, length(group)} end)

      assert grouped == Enum.frequencies_by(values, key)
    end
  end

  property "Enum.into MapSet mapper and MapSet.new mapper are equivalent" do
    check all(values <- list_of(integer()), offset <- integer()) do
      mapper = &(&1 + offset)

      assert Enum.into(values, MapSet.new(), mapper) == MapSet.new(values, mapper)
    end
  end

  property "joining duplicated strings and String.duplicate are equivalent" do
    check all(value <- string(:alphanumeric), count <- integer(0..20)) do
      assert value |> List.duplicate(count) |> Enum.join() == String.duplicate(value, count)
    end
  end

  property "deduplicating before MapSet construction is redundant" do
    check all(values <- list_of(integer())) do
      assert values |> Enum.uniq() |> MapSet.new() == MapSet.new(values)
    end
  end

  property "materializing an enumerable before Map.new is redundant" do
    check all(pairs <- list_of(tuple({integer(), integer()}))) do
      assert pairs |> Enum.to_list() |> Map.new() == Map.new(pairs)
    end
  end
end
