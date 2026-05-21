defmodule Reach.Evidence.MapContractTest do
  use ExUnit.Case, async: true

  alias Reach.Evidence.MapContract

  test "collects map contracts with creation and later key flow evidence" do
    ast =
      Code.string_to_quoted!("""
      def build(user) do
        profile = %{id: user.id, name: user.name, email: user.email}
        Map.get(profile, :id)
        profile.name
      end
      """)

    assert [contract] = MapContract.collect_ast(ast)
    assert contract.variable == :profile
    assert contract.keys == [:email, :id, :name]
    assert Enum.map(contract.reads, & &1.key) |> Enum.sort() == [:id, :name]
    assert contract.confidence == :medium
  end

  test "accounts for updates as stronger contract evidence" do
    ast =
      Code.string_to_quoted!("""
      def build(user) do
        profile = %{id: user.id, name: user.name, email: user.email}
        profile = Map.put(profile, :email, String.downcase(profile.email))
        profile.name
      end
      """)

    assert [contract] = MapContract.collect_ast(ast)
    assert [%{key: :email, kind: :update}] = contract.updates
    assert contract.confidence == :medium
  end

  test "ignores map literals without later flow evidence" do
    ast =
      Code.string_to_quoted!("""
      def build(user) do
        %{id: user.id, name: user.name, email: user.email}
      end
      """)

    assert [] = MapContract.collect_ast(ast)
  end
end
