defmodule Reach.Evidence.StandardLibraryBypass do
  @moduledoc "Collects evidence of ad-hoc code that bypasses standard library helpers."

  defmodule Evidence do
    @moduledoc false
    defstruct [:kind, :message, :replacement, :meta, :confidence]
  end

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
    {_ast, evidence} =
      Macro.prewalk(ast, [], fn node, acc ->
        {node, collect_node(node, acc)}
      end)

    Enum.reverse(evidence)
  end

  defp collect_node(node, acc) do
    Enum.reduce(@families, acc, fn family, acc -> family.collect_node(node, acc) end)
  end
end
