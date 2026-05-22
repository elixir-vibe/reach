defmodule Reach.EvidenceTest do
  use ExUnit.Case, async: true

  test "discovers built-in AST evidence providers" do
    providers = Reach.Evidence.ast_providers([])

    assert Reach.Evidence.StandardLibraryBypass in providers
    assert Reach.Evidence.MapContract in providers
  end

  test "discovers plugin AST evidence providers" do
    providers = Reach.Evidence.ast_providers([Reach.Plugins.Jason])

    assert Reach.Plugins.Jason.Evidence.HandRolledEncoder in providers
  end

  test "filters providers by family" do
    assert Reach.Evidence.ast_providers_for(:stdlib, []) == [Reach.Evidence.StandardLibraryBypass]
  end
end
