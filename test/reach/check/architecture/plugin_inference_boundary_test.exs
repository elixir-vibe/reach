defmodule Reach.Check.Architecture.PluginInferenceBoundaryTest do
  use ExUnit.Case, async: true

  @framework_terms ~w(Phoenix Ecto Oban Ash Nx Jason Poison ExUnit GenStage Broadway OpenTelemetry QuickBEAM Jido)

  test "plugin inference core does not centralize framework hints" do
    source = File.read!("lib/reach/plugin/inference.ex")

    for term <- @framework_terms do
      refute source =~ term
    end
  end
end
