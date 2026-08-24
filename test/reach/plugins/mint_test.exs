defmodule Reach.Plugins.MintTest do
  use ExUnit.Case, async: true

  alias Reach.IR.Node
  alias Reach.Plugins.Mint

  test "classifies HTTP connection operations as IO" do
    for function <- [
          :close,
          :connect,
          :connect_proxy,
          :controlling_process,
          :request,
          :stream,
          :stream_request_body
        ] do
      node = %Node{
        id: 0,
        type: :call,
        meta: %{kind: :remote, module: Elixir.Mint.HTTP, function: function}
      }

      assert Reach.Plugin.classify_effect([Mint], node) == :io
    end
  end

  test "does not classify pure connection inspection" do
    node = %Node{
      id: 0,
      type: :call,
      meta: %{kind: :remote, module: Elixir.Mint.HTTP, function: :open?}
    }

    assert Reach.Plugin.classify_effect([Mint], node) == nil
  end
end
