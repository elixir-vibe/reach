defmodule ReachCalibration.CLITest do
  use ExUnit.Case, async: true

  alias ReachCalibration.CLI

  test "documents the Exograph calibration options" do
    usage = CLI.usage()

    assert usage =~ "--base-url"
    assert usage =~ "--labels"
    assert usage =~ "--kinds"
    assert usage =~ "--candidate-limit"
    assert usage =~ "--seed"
  end

  test "parses repeated paths and validates detector kinds" do
    config =
      CLI.parse!([
        "--paths",
        "lib/**",
        "--paths",
        "config/**",
        "--kinds",
        "dual_key_fallback,false_collapsing_lookup",
        "--limit",
        "10"
      ])

    assert config.paths == ["lib/**", "config/**"]
    assert config.kinds == [:dual_key_fallback, :false_collapsing_lookup]
    assert config.limit == 10
  end
end
