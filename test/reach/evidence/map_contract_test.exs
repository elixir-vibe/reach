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

  test "tracks shallow aliases and escapes" do
    ast =
      Code.string_to_quoted!("""
      def render(user) do
        profile = %{id: user.id, name: user.name, email: user.email}
        data = profile
        data.id
        data.email
        send_profile(data)
      end
      """)

    assert [data] = MapContract.collect_ast(ast)
    assert data.variable == :data
    assert data.observed_keys == [:email, :id]
    assert data.escaped?
    assert [%{module: nil, function: :send_profile, arity: 1}] = data.escapes
  end

  test "records remote escape targets" do
    ast =
      Code.string_to_quoted!("""
      def render(user) do
        data = %{id: user.id, name: user.name, email: user.email}
        data.id
        data.email
        Jason.encode!(data)
      end
      """)

    assert [contract] = MapContract.collect_ast(ast)
    assert contract.escaped?
    assert [%{module: Jason, function: :encode!, arity: 1}] = contract.escapes
  end

  test "connects fixed-shape return map bindings to local callsite reads" do
    ast =
      Code.string_to_quoted!("""
      def profile(user) do
        profile = %{id: user.id, name: user.name, email: user.email}
        result = profile
        result
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
    assert contract.keys == [:email, :id, :name]
    assert contract.observed_keys == [:email, :id]
  end

  test "collects project-level remote return shape contracts" do
    dir = Path.join(System.tmp_dir!(), "reach-map-project-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    producer = Path.join(dir, "producer.ex")
    consumer = Path.join(dir, "consumer.ex")

    File.write!(producer, """
    defmodule Accounts.Profile do
      def build(user) do
        profile = %{id: user.id, name: user.name, email: user.email}
        result = profile
        result
      end
    end
    """)

    File.write!(consumer, """
    defmodule Web.ProfileView do
      def render(user) do
        data = Accounts.Profile.build(user)
        data.id
        data.email
      end
    end
    """)

    project = Reach.Project.from_sources([producer, consumer], plugins: [])

    assert [contract] =
             project
             |> MapContract.collect_project()
             |> Enum.filter(&(&1.source == :cross_file_return))

    assert contract.file == consumer
    assert contract.producer == {Accounts.Profile, :build, 1}
    assert contract.consumer == {Web.ProfileView, :render, 1}
    assert contract.role == :domain
    assert contract.observed_keys == [:email, :id]

    File.rm_rf(dir)
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
