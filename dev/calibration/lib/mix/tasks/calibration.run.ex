defmodule Mix.Tasks.Calibration.Run do
  @moduledoc "Runs reproducible Reach detector calibration against an Exograph corpus."

  use Mix.Task

  alias ReachCalibration.{CLI, Config, Report, Runner}

  @shortdoc "Run Reach corpus calibration"

  @impl Mix.Task
  def run(argv) do
    config = CLI.parse!(argv)

    if config.help do
      Mix.shell().info(CLI.usage())
    else
      Application.ensure_all_started(:reach_calibration)
      run_calibration(config)
    end
  rescue
    error in [ArgumentError, NimbleOptions.ValidationError] -> Mix.raise(Exception.message(error))
  end

  defp run_calibration(config) do
    case Runner.run(Config.runner_options(config)) do
      {:ok, report} ->
        output = Report.write!(report, config.output)
        Report.print(report, output)

      {:error, reason} ->
        Mix.raise("Exograph calibration failed: #{inspect(reason)}")
    end
  end
end
