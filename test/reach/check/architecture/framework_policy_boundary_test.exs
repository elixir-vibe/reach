defmodule Reach.Check.Architecture.FrameworkPolicyBoundaryTest do
  use ExUnit.Case, async: true

  @generic_policy_files [
    "lib/reach/analysis.ex",
    "lib/reach/map/analysis.ex",
    "lib/reach/otp/analysis.ex"
  ]

  @framework_terms ~w(Phoenix Ecto Oban Ash Nx Jason Poison ExUnit GenStage Broadway OpenTelemetry QuickBEAM Jido)
  @framework_callbacks ~w(mount handle_event handle_params perform handle_batch handle_demand handle_events)

  test "generic analysis modules do not encode framework policy" do
    for file <- @generic_policy_files do
      source = File.read!(file)

      for term <- @framework_terms ++ @framework_callbacks do
        refute source =~ term, "#{file} contains framework-specific policy term #{inspect(term)}"
      end
    end
  end
end
