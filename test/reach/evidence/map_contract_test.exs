defmodule Reach.Evidence.MapContractTest do
  use ExUnit.Case, async: true

  alias Reach.Evidence.MapContract

  test "exposes evidence metadata" do
    assert MapContract.family() == :map_contract
    assert MapContract.kinds() == [:implicit_map_contract]
  end

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
    assert contract.role == :unknown
    assert contract.key_coverage == 2 / 3
    assert contract.observed_keys == [:id, :name]
    assert contract.unused_keys == [:email]
    assert contract.read_count == 2
    assert contract.mutation_count == 0
    refute contract.escaped?
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

  test "connects fixed-shape return maps to local callsite reads" do
    ast =
      Code.string_to_quoted!("""
      def profile(user) do
        %{id: user.id, name: user.name, email: user.email}
      end

      def render(user) do
        data = profile(user)
        data.id
        Map.get(data, :email)
      end
      """)

    assert [contract] = MapContract.collect_ast(ast)
    assert contract.source == :return
    assert contract.producer == {:profile, 1}
    assert contract.variable == :data
    assert Enum.map(contract.reads, & &1.key) |> Enum.sort() == [:email, :id]
    assert contract.role == :domain
  end

  test "classifies common non-domain map roles" do
    ast =
      Code.string_to_quoted!("""
      def render(input) do
        assigns = %{title: input.title, body: input.body, user: input.user}
        assigns.title
        assigns.body
      end

      def reduce(items) do
        acc = %{seen: [], count: 0, errors: []}
        acc.seen
        acc.count
      end

      def send_payload(input) do
        payload = %{id: input.id, name: input.name, email: input.email}
        payload.id
        payload.email
      end
      """)

    contracts = MapContract.collect_ast(ast)

    assert Enum.find(contracts, &(&1.variable == :assigns)).role == :assigns
    assert Enum.find(contracts, &(&1.variable == :acc)).role == :accumulator
    assert Enum.find(contracts, &(&1.variable == :payload)).role == :external_payload
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
