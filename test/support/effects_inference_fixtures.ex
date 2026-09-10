defmodule Reach.Test.Effects.InferenceFixtures do
  @moduledoc false

  defmodule CompiledProjectModule do
    @moduledoc false
    def unresolved(callback, value), do: callback.(value)
    def caller(callback, value), do: unresolved(callback, value)
  end

  defmodule NestedDependency do
    @moduledoc false
    def double(value), do: value * 2
  end

  defmodule CompiledDependency do
    @moduledoc false
    def first(value), do: value + 1
    def second(value), do: NestedDependency.double(value)
  end

  defmodule WideDependency do
    @moduledoc false
    @target_count 100

    for index <- 1..@target_count do
      def unquote(:"target_#{index}")(value), do: helper(value)
    end

    defp helper(value), do: value + 1
  end

  defmodule BatchedTargets do
    @moduledoc false
    def first(value), do: helper(value)
    def second(value), do: helper(value)
    defp helper(value), do: leaf(value)
    defp leaf(value), do: value + 1
  end
end
