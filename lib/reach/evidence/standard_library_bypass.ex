defmodule Reach.Evidence.StandardLibraryBypass do
  @moduledoc "Collects evidence of ad-hoc code that bypasses standard library helpers."
  @behaviour Reach.Evidence.Provider

  alias Reach.Evidence.{Bypass, Fact}

  @families [
    Reach.Evidence.StandardLibraryBypass.PathURI,
    Reach.Evidence.StandardLibraryBypass.Enum,
    Reach.Evidence.StandardLibraryBypass.Map
  ]

  @impl true
  def family, do: :stdlib

  @impl true
  def kinds do
    @families
    |> Enum.flat_map(& &1.kinds())
    |> Enum.uniq()
  end

  def fact(kind, message, replacement, meta, confidence \\ :high) do
    %Fact{
      family: :stdlib,
      kind: kind,
      message: message,
      replacement: replacement,
      meta: meta,
      confidence: confidence
    }
  end

  @impl true
  def collect_ast(ast) do
    @families
    |> Enum.flat_map(& &1.collect_ast(ast))
    |> Enum.map(fn fact ->
      Bypass.annotate(fact,
        provider: :elixir_standard_library,
        capability: fact.kind,
        origin: :stdlib_pattern
      )
    end)
    |> Enum.sort_by(&{&1.meta[:line] || 0, &1.meta[:column] || 0, &1.kind})
  end
end
