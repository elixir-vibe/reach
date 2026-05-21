defmodule Reach.Evidence.StandardLibraryBypass do
  @moduledoc "Collects evidence of ad-hoc code that bypasses standard library helpers."

  @families [
    Reach.Evidence.StandardLibraryBypass.PathURI,
    Reach.Evidence.StandardLibraryBypass.Enum,
    Reach.Evidence.StandardLibraryBypass.Map
  ]

  def family, do: :stdlib

  def kinds do
    @families
    |> Enum.flat_map(& &1.kinds())
    |> Enum.uniq()
  end

  def collect_ast(ast) do
    @families
    |> Enum.flat_map(& &1.collect_ast(ast))
    |> Enum.sort_by(&{&1.meta[:line] || 0, &1.meta[:column] || 0, &1.kind})
  end
end
