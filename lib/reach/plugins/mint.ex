defmodule Reach.Plugins.Mint do
  @moduledoc "Plugin for Mint HTTP connection effects."
  @behaviour Reach.Plugin

  alias Reach.IR.Node

  @network_functions [
    :close,
    :connect,
    :connect_proxy,
    :controlling_process,
    :request,
    :stream,
    :stream_request_body
  ]

  @impl true
  def inference_hints do
    %{deps: [:mint], source: ["Mint.HTTP"]}
  end

  @impl true
  def classify_effect(%Node{type: :call, meta: %{module: Elixir.Mint.HTTP, function: function}})
      when function in @network_functions,
      do: :io

  def classify_effect(_node), do: nil

  @impl true
  def analyze(_all_nodes, _opts), do: []
end
