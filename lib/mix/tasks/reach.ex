defmodule Mix.Tasks.Reach do
  @moduledoc """
  Generates an interactive HTML report for Elixir/Erlang/Gleam/JavaScript source files.
  """

  use Mix.Task

  alias Reach.CLI.Commands.Report
  alias Reach.CLI.Options
  alias Reach.CLI.Pipe

  @shortdoc "Generate interactive HTML report"

  @help """
  Generates an interactive HTML report for Elixir/Erlang/Gleam/JavaScript source files.

      mix reach
      mix reach lib/my_app/server.ex
      mix reach --dead-code
      mix reach --format dot

  Options:

    --format      Output format: html (default), dot, json
    --output      Output directory (default: reach_report)
    --open        Open browser after generating
    --no-open     Do not open browser after generating
    --dead-code   Highlight dead code
    --help        Show this help
  """

  @switches [
    output: :string,
    format: :string,
    open: :boolean,
    dead_code: :boolean,
    help: :boolean
  ]

  @aliases [o: :output, f: :format, h: :help]

  @impl Mix.Task
  def run(args) do
    Pipe.safely(fn ->
      {opts, files} = Options.parse(args, @switches, @aliases)

      if opts[:help] do
        Mix.shell().info(@help)
      else
        Report.run(opts, files)
      end
    end)
  end
end
