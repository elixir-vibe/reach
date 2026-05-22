defmodule Reach.Plugin.EvidenceRefinementTest do
  use ExUnit.Case, async: true

  alias Reach.Evidence.Fact
  alias Reach.Evidence.MapContract
  alias Reach.Plugin

  defmodule RolePlugin do
    @behaviour Reach.Plugin

    @impl true
    def analyze(_nodes, _opts), do: []

    @impl true
    def classify_effect(_node), do: nil

    @impl true
    def refine_evidence(%MapContract.Contract{variable: :data}, _context) do
      %{role: :external_payload}
    end

    def refine_evidence(%Fact{} = fact, _context) do
      %{fact | confidence: :medium}
    end

    def refine_evidence(_evidence, _context), do: :unchanged
  end

  test "plugins can refine evidence maps or structs" do
    fact = %Fact{family: :stdlib, kind: :manual_flat_map, confidence: :high}

    assert %Fact{confidence: :medium} = Plugin.refine_evidence([RolePlugin], fact, %{})
  end

  test "map contract collection applies plugin role refinements" do
    ast =
      Code.string_to_quoted!("""
      def build(user) do
        data = %{id: user.id, name: user.name, email: user.email}
        data.id
        data.email
      end
      """)

    assert [%{role: :external_payload}] = MapContract.collect_ast(ast, plugins: [RolePlugin])
  end

  test "Jason plugin classifies encoded maps as external payloads" do
    ast =
      Code.string_to_quoted!("""
      def build(user) do
        data = %{id: user.id, name: user.name, email: user.email}
        data.id
        data.email
        Jason.encode!(data)
      end
      """)

    assert [%{role: :external_payload}] =
             MapContract.collect_ast(ast, plugins: [Reach.Plugins.Jason])
  end
end
