defmodule ReachCalibration.MixProject do
  use Mix.Project

  def project do
    [
      app: :reach_calibration,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def cli do
    [preferred_envs: [ci: :test]]
  end

  def application do
    [extra_applications: [:crypto, :logger]]
  end

  defp deps do
    [
      {:reach, path: "../.."},
      {:nimble_options, "~> 1.1"},
      {:req, "~> 0.5"}
    ]
  end

  defp aliases do
    [
      ci: ["format --check-formatted", "compile --warnings-as-errors", "test"]
    ]
  end
end
