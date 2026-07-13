defmodule Reach.Scripts.ExographCorpusScanTest do
  use ExUnit.Case, async: false

  test "documents the Exograph calibration options" do
    {output, 0} =
      System.cmd(
        "mix",
        ["run", "--no-compile", "scripts/exograph_corpus_scan.exs", "--", "--help"],
        stderr_to_stdout: true
      )

    assert output =~ "--base-url"
    assert output =~ "--labels"
    assert output =~ "--kinds"
  end
end
