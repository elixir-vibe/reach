defmodule Mix.Tasks.Reach.Trace do
  @moduledoc """
  Traces data flow, taint paths, and forward/backward slices.

      mix reach.trace --from params --to write!
      mix reach.trace --from input --to System.cmd
      mix reach.trace --pattern regex-on-structured
      mix reach.trace --variable user --in MyApp.Accounts.create/1
      mix reach.trace --backward lib/my_app/accounts.ex:45
      mix reach.trace --forward lib/my_app/accounts.ex:45

  ## Options

    * `--from` — taint source pattern
    * `--to` — sink pattern
    * `--pattern` — run a named source-to-sink trace preset
    * `--variable` — trace a variable name
    * `--in` — restrict variable tracing to a function
    * `--backward` — compute a backward slice from a target
    * `--forward` — compute a forward slice from a target
    * `--format` — output format: `text`, `json`, `oneline`
    * `--graph` — render slice graph where supported
    * `--limit` — text display limit for paths/rows; also caps taint paths unless `--all` is set
    * `--all` — show all text rows/paths and collect all taint paths

  """

  use Mix.Task

  alias Reach.CLI.Commands.Trace
  alias Reach.CLI.Options
  alias Reach.CLI.Pipe

  @shortdoc "Trace data flow, taint paths, and slices"

  @switches [
    format: :string,
    from: :string,
    to: :string,
    pattern: :string,
    variable: :string,
    in: :string,
    backward: :string,
    forward: :string,
    graph: :boolean,
    limit: :integer,
    all: :boolean
  ]

  @aliases [f: :format]

  @impl Mix.Task
  def run(args) do
    Pipe.safely(fn ->
      {opts, positional} = Options.parse(args, @switches, @aliases)
      Trace.run(opts, positional)
    end)
  end
end
