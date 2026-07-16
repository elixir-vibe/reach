defmodule Reach.Check.Architecture.CalibrationBoundaryTest do
  use ExUnit.Case, async: true

  test "calibration tooling is excluded from the Reach runtime and package" do
    assert Path.wildcard("lib/reach/calibration/**/*.ex") == []

    package_files =
      Reach.MixProject.project() |> Keyword.fetch!(:package) |> Keyword.fetch!(:files)

    refute "dev" in package_files
  end
end
